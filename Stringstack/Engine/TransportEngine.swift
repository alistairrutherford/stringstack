import AVFoundation
import AudioToolbox
import Observation

/// Owns the AVAudioEngine graph, the session model, and the transport state
/// machine.
///
/// The metronome's render clock is the single source of timing truth; the UI
/// polls `currentBeats` from a `TimelineView` rather than observing it.
/// Transport starts are anchored to a host time slightly in the future, and
/// quantised clip launches/stops are scheduled against that same clock:
/// launches sample-accurately via `AVAudioPlayerNode.play(at:)`, boundary
/// bookkeeping (stopping the outgoing player, UI state) via async tasks.
@MainActor
@Observable
final class TransportEngine {

    enum Mode: Equatable {
        case stopped
        case playing
        case recording
    }

    private(set) var mode: Mode = .stopped
    private(set) var tracks: [Track] = []
    private(set) var sceneCount = 4
    /// Track whose device chain is shown in the FX bar.
    var selectedTrackID: UUID?

    var selectedTrack: Track? {
        tracks.first { $0.id == selectedTrackID } ?? tracks.first
    }

    /// Per-track playing/queued state for the grid UI.
    private(set) var playback: [UUID: TrackPlayback] = [:]
    /// The slot currently being recorded into, if any.
    private(set) var recordingSlot: SlotRef?
    /// Non-nil while a rolling-transport recording waits for its bar boundary.
    private(set) var recordQueuedUntilBeat: Double?
    /// Last-clicked clip slot; DEL deletes it.
    var selectedSlot: SlotRef?
    /// Last-clicked scene row, outlined in the grid.
    var selectedScene: Int?
    /// Fixed record length in bars; nil records freely until stopped.
    var recordLengthBars: Int? = 4

    var quantize: LaunchQuantize = .bar {
        didSet { markDirty() }
    }
    var engineError: String?
    /// Transient, non-fatal feedback ("clip too short", device unplugged…).
    var statusMessage: String?
    /// Where ⌘S saves without asking; set by the save/open panels.
    var projectURL: URL?
    /// True once the project has edits not yet written to disk. Drives the
    /// "save changes?" prompt on New Project.
    private(set) var hasUnsavedChanges = false
    /// Set while loading/resetting so bulk model changes don't mark dirty.
    @ObservationIgnored private var suppressDirty = false

    func markDirty() {
        if !suppressDirty { hasUnsavedChanges = true }
    }

    func markSaved() {
        hasUnsavedChanges = false
    }

    /// Undo/redo for clip edits (⌘Z / ⇧⌘Z).
    @ObservationIgnored let undoManager = UndoManager()

    let devices = DeviceManager()

    var tempo: Double = 120 {
        didSet {
            let clamped = min(max(tempo.rounded(), 20), 300)
            if clamped != tempo { tempo = clamped }
            metronome.setTempo(tempo)
            markDirty()
        }
    }

    var beatsPerBar = 4 {
        didSet {
            metronome.setBeatsPerBar(beatsPerBar)
            markDirty()
        }
    }

    /// Count-in length in bars, applied when recording starts from stopped.
    var countInBars = 2 {
        didSet { markDirty() }
    }

    var metronomeEnabled = true {
        didSet { metronome.setClickAudible(metronomeEnabled) }
    }

    var metronomeVolume = 0.7 {
        didSet { metronome.setVolume(metronomeVolume) }
    }

    var masterVolume = 0.9 {
        didSet {
            audioEngine.mainMixerNode.outputVolume = Float(masterVolume)
            markDirty()
        }
    }

    /// Total count-in beats of the transport run currently in progress.
    @ObservationIgnored private(set) var activeCountInBeats = 0

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let metronome: MetronomeSource
    @ObservationIgnored private let recorder = RecordingService()
    @ObservationIgnored let masterMeter = MeterTap()
    @ObservationIgnored private var channels: [UUID: TrackChannel] = [:]
    @ObservationIgnored private var beat0Host: UInt64 = 0
    @ObservationIgnored private var recordTempo: Double = 120
    @ObservationIgnored private var recordStartBeat = 0.0
    @ObservationIgnored private var inputConfigured = false
    @ObservationIgnored private var recordAutoStopTask: Task<Void, Never>?
    /// When recording an overdub, the existing clip being layered onto; its
    /// length also fixes the take length via `recordBarsOverride`.
    @ObservationIgnored private var overdubSource: Clip?
    @ObservationIgnored private var recordBarsOverride: Int?
    /// A Replace-mode take that must clear its slot once recording begins.
    @ObservationIgnored private var replaceClearPending = false
    /// Every clip buffer is converted to this on creation, so any clip can
    /// play on any (permanently connected) track player.
    @ObservationIgnored private(set) var standardFormat: AVAudioFormat

    /// Beats since bar 1 started; negative while counting in. Poll, don't observe.
    var currentBeats: Double { metronome.currentBeats }

    var isCountingIn: Bool { mode == .recording && currentBeats < 0 }

    /// Smoothed input level (0...1) while capturing. Poll, don't observe.
    var inputPeak: Double { recorder.inputPeak }

    var armedTrack: Track? { tracks.first { $0.isArmed } }

    init() {
        var sampleRate = audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0 { sampleRate = 44100 }
        metronome = MetronomeSource(sampleRate: sampleRate)
        standardFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        audioEngine.attach(metronome.node)
        audioEngine.connect(metronome.node, to: audioEngine.mainMixerNode, format: nil)
        audioEngine.mainMixerNode.outputVolume = Float(masterVolume)
        startEngine()
        masterMeter.install(on: audioEngine.mainMixerNode)

        for index in 0..<4 { addTrack(named: "Track \(index + 1)") }
        selectedTrackID = tracks.first?.id
        if sceneCount > 0 { selectedScene = 0 }

        devices.onDeviceListChanged = { [weak self] in
            self?.handleDeviceListChange()
        }

        if !UserDefaults.standard.bool(forKey: "didInstallDemoSet") {
            UserDefaults.standard.set(true, forKey: "didInstallDemoSet")
            DemoFactory.install(into: self)
        }
        // A fresh launch (incl. the demo set) is not an unsaved user edit.
        hasUnsavedChanges = false

        // Autosave every two minutes once the project has a home, while idle.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard let self else { return }
                if let url = self.projectURL, self.mode == .stopped {
                    try? ProjectStore.write(engine: self, to: url)
                }
            }
        }
    }

    // MARK: - Saving

    func saveInPlace() {
        guard let url = projectURL else {
            ProjectStore.saveWithPanel(engine: self)
            return
        }
        do {
            try ProjectStore.write(engine: self, to: url)
            statusMessage = "Saved \(url.lastPathComponent)"
        } catch {
            engineError = "Couldn't save project: \(error.localizedDescription)"
        }
    }

    // MARK: - Undo

    private func registerUndo(_ actionName: String,
                              _ handler: @escaping (TransportEngine) -> Void) {
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { handler(target) }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Session structure

    func addTrack(named name: String? = nil) {
        let track = Track(name: name ?? "Track \(tracks.count + 1)",
                          colorIndex: tracks.count % 6,
                          sceneCount: sceneCount)
        let channel = TrackChannel()
        audioEngine.attach(channel.mixer)
        audioEngine.attach(channel.players[0])
        audioEngine.attach(channel.players[1])
        audioEngine.attach(channel.inputMixer)
        audioEngine.connect(channel.players[0], to: channel.inputMixer, format: standardFormat)
        audioEngine.connect(channel.players[1], to: channel.inputMixer, format: standardFormat)
        audioEngine.connect(channel.inputMixer, to: channel.mixer, format: standardFormat)
        audioEngine.connect(channel.mixer, to: audioEngine.mainMixerNode, format: nil)
        channel.meter.install(on: channel.mixer)
        channels[track.id] = channel
        tracks.append(track)
        applyMix(track)
        markDirty()
    }

    func deleteTrack(_ track: Track) {
        if recordingSlot?.trackID == track.id { stop() }
        for effect in track.effects {
            PluginWindows.close(effect.id)
            audioEngine.detach(effect.node)
        }
        track.effects.removeAll()
        if let channel = channels[track.id] {
            channel.pendingTask?.cancel()
            channel.stopAllPlayers()
            channel.mixer.removeTap(onBus: 0)
            audioEngine.detach(channel.players[0])
            audioEngine.detach(channel.players[1])
            audioEngine.detach(channel.inputMixer)
            audioEngine.detach(channel.mixer)
        }
        channels.removeValue(forKey: track.id)
        playback.removeValue(forKey: track.id)
        tracks.removeAll { $0.id == track.id }
        if selectedTrackID == track.id { selectedTrackID = tracks.first?.id }
        if selectedSlot?.trackID == track.id { selectedSlot = nil }
        applyMixAll()
        markDirty()
    }

    func addScene() {
        sceneCount += 1
        for track in tracks { track.slots.append(nil) }
        markDirty()
    }

    /// Selecting a track drops any clip selection on other tracks, so DEL
    /// always targets what the eye is on.
    func selectTrack(_ track: Track) {
        selectedTrackID = track.id
        if let slot = selectedSlot, slot.trackID != track.id {
            selectedSlot = nil
        }
    }

    func selectScene(_ scene: Int) {
        guard scene >= 0, scene < sceneCount else { return }
        selectedScene = scene
    }

    // MARK: - Mixing

    func setVolume(_ track: Track, _ volume: Double) {
        selectTrack(track)
        track.volume = volume
        applyMix(track)
        markDirty()
    }

    func setPan(_ track: Track, _ pan: Double) {
        selectTrack(track)
        track.pan = pan
        applyMix(track)
        markDirty()
    }

    func toggleMute(_ track: Track) {
        selectTrack(track)
        track.isMuted.toggle()
        applyMixAll()
        markDirty()
    }

    /// Exclusive solo: soloing a track silences every other track, so only
    /// this one plays. Clicking an already-soloed track clears solo.
    func toggleSolo(_ track: Track) {
        selectTrack(track)
        let willSolo = !track.isSoloed
        for other in tracks { other.isSoloed = false }
        track.isSoloed = willSolo
        applyMixAll()
        markDirty()
    }

    /// Record-into-occupied-clip mode: overdub (layer) when on, replace when off.
    func toggleOverdub(_ track: Track) {
        selectTrack(track)
        track.isOverdub.toggle()
        markDirty()
    }

    func meterLevels(for track: Track) -> (left: Double, right: Double) {
        channels[track.id]?.meter.levels ?? (0, 0)
    }

    private func applyMixAll() {
        for track in tracks { applyMix(track) }
    }

    private func applyMix(_ track: Track) {
        guard let channel = channels[track.id] else { return }
        let anySolo = tracks.contains { $0.isSoloed }
        let audible = !track.isMuted && (!anySolo || track.isSoloed)
        channel.mixer.outputVolume = audible ? Float(track.volume) : 0
        channel.mixer.pan = Float(track.pan)
    }

    // MARK: - AU effects

    /// Installed AU effects (`aufx`), sorted by manufacturer then name.
    func effectComponents() -> [AVAudioUnitComponent] {
        var description = AudioComponentDescription()
        description.componentType = kAudioUnitType_Effect
        return AVAudioUnitComponentManager.shared().components(matching: description)
            .sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
    }

    func addEffect(_ component: AVAudioUnitComponent, to track: Track) {
        let description = component.audioComponentDescription
        let name = component.name
        let manufacturer = component.manufacturerName
        Task {
            do {
                let unit = try await AVAudioUnit.instantiate(with: description, options: [])
                audioEngine.attach(unit)
                let effect = EffectInstance(name: name, manufacturer: manufacturer,
                                            componentDescription: description, node: unit)
                track.effects.append(effect)
                rebuildChain(for: track)
                markDirty()
                statusMessage = nil
            } catch {
                statusMessage = "Couldn't load \(name): \(error.localizedDescription)"
            }
        }
    }

    func removeEffect(_ effect: EffectInstance, from track: Track) {
        PluginWindows.close(effect.id)
        track.effects.removeAll { $0.id == effect.id }
        rebuildChain(for: track)
        audioEngine.detach(effect.node)
        markDirty()
    }

    /// Moves an effect one step left (-1) or right (+1) in the chain.
    func moveEffect(_ effect: EffectInstance, in track: Track, by offset: Int) {
        guard let index = track.effects.firstIndex(where: { $0.id == effect.id }) else { return }
        let target = index + offset
        guard target >= 0, target < track.effects.count else { return }
        track.effects.swapAt(index, target)
        rebuildChain(for: track)
        markDirty()
    }

    /// Reconnects inputMixer → effects… → fader mixer in chain order.
    /// Bypass doesn't rebuild — it uses `shouldBypassEffect` on the node.
    private func rebuildChain(for track: Track) {
        guard let channel = channels[track.id] else { return }
        audioEngine.disconnectNodeOutput(channel.inputMixer)
        for effect in track.effects {
            audioEngine.disconnectNodeOutput(effect.node)
        }
        var current: AVAudioNode = channel.inputMixer
        for effect in track.effects {
            audioEngine.connect(current, to: effect.node, format: standardFormat)
            current = effect.node
        }
        audioEngine.connect(current, to: channel.mixer, format: standardFormat)
    }

    /// Re-instantiates a saved effect and applies its archived state.
    func restoreEffect(name: String, manufacturer: String,
                       description: AudioComponentDescription,
                       state: Data?, bypassed: Bool, on track: Track) async {
        do {
            let unit = try await AVAudioUnit.instantiate(with: description, options: [])
            audioEngine.attach(unit)
            if let state,
               let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: state) {
                unarchiver.requiresSecureCoding = false
                if let fullState = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [String: Any] {
                    unit.auAudioUnit.fullState = fullState
                }
            }
            let effect = EffectInstance(name: name, manufacturer: manufacturer,
                                        componentDescription: description, node: unit)
            effect.isBypassed = bypassed
            track.effects.append(effect)
            rebuildChain(for: track)
        } catch {
            statusMessage = "Couldn't restore effect \(name) — is the plugin still installed?"
        }
    }

    // MARK: - Arming & input

    func toggleArm(_ track: Track) {
        if track.isArmed {
            track.isArmed = false
            return
        }
        guard mode != .recording else { return }
        if inputConfigured {
            armOnly(track)
        } else {
            guard mode == .stopped else {
                statusMessage = "Stop the transport before arming for the first time."
                return
            }
            Task { await configureInput(thenArm: track) }
        }
    }

    /// One armed track at a time — there is one recording input. Selection
    /// follows the armed track so the FX bar and shortcuts focus with it.
    private func armOnly(_ track: Track) {
        for other in tracks { other.isArmed = (other.id == track.id) }
        selectTrack(track)
    }

    func selectInputDevice(_ id: AudioDeviceID) {
        guard devices.selectedDeviceID != id else { return }
        devices.selectedDeviceID = id
        guard inputConfigured else { return }
        if mode == .stopped {
            Task { await configureInput() }
        } else {
            inputConfigured = false
            statusMessage = "Input change applies once the transport stops — re-arm the track."
        }
    }

    private func configureInput(thenArm track: Track? = nil) async {
        guard await AVAudioApplication.requestRecordPermission() else {
            engineError = "Microphone access denied — enable it in System Settings › Privacy & Security › Microphone."
            return
        }
        inputDebugLog("=== configureInput; permission=\(AVAudioApplication.shared.recordPermission.rawValue) selected=\(devices.selectedDevice?.name ?? "nil") isDefault=\(devices.isSelectedDeviceSystemDefault)")

        // Only touch the I/O unit's device when the user picked a
        // non-default input; on macOS input/output can share one HAL unit
        // and re-pointing it at a mic device can fail output init (-10875).
        let needsExplicitDevice = !devices.isSelectedDeviceSystemDefault
        do {
            try restartEngineWithInput(setDevice: needsExplicitDevice)
            inputConfigured = true
            engineError = nil
            statusMessage = nil
            if let track { armOnly(track) }
            inputDebugLog("configureInput OK (explicitDevice=\(needsExplicitDevice))")
        } catch {
            inputDebugLog("attempt 1 failed: \(error)")
            // Retry without touching the device at all — the engine then
            // captures from the system default input.
            do {
                try restartEngineWithInput(setDevice: false)
                devices.markSelectionAsSystemDefault()
                inputConfigured = true
                engineError = nil
                statusMessage = "Using the system default input device."
                if let track { armOnly(track) }
                inputDebugLog("attempt 2 (no device set) OK")
            } catch {
                inputDebugLog("attempt 2 failed: \(error)")
                recorder.removeTap(from: audioEngine.inputNode)
                inputConfigured = false
                engineError = "Could not configure input: \(error.localizedDescription) — if this app was rebuilt recently, macOS may hold a stale microphone grant; run `tccutil reset Microphone com.example.Stringstack` in Terminal and try again."
                startEngine()
            }
        }
    }

    /// Full input bring-up. Ordering matters: reset tears down the previous
    /// render state so a device change takes; prepare initialises I/O so
    /// the input bus reports real formats; the tap must be in place before
    /// start so the input unit comes up connected.
    private func restartEngineWithInput(setDevice: Bool) throws {
        let input = audioEngine.inputNode
        audioEngine.stop()
        recorder.removeTap(from: input)
        audioEngine.reset()
        if setDevice {
            try devices.applySelectedDevice(to: input)
        }
        audioEngine.prepare()

        let sharedUnit = input.audioUnit != nil && input.audioUnit == audioEngine.outputNode.audioUnit
        let hardware = input.inputFormat(forBus: 0)
        let bus = input.outputFormat(forBus: 0)
        inputDebugLog("bring-up setDevice=\(setDevice) sharedIOUnit=\(sharedUnit) hw=\(Int(hardware.sampleRate))Hz/\(hardware.channelCount)ch bus=\(Int(bus.sampleRate))Hz/\(bus.channelCount)ch")

        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw NSError(domain: "Stringstack", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Input device reports no usable channels (\(Int(hardware.sampleRate)) Hz, \(hardware.channelCount) ch)",
            ])
        }
        recorder.installTap(on: input)
        try audioEngine.start()
    }

    /// Appends a line to Application Support/input-debug.log so input
    /// bring-up failures can be diagnosed after the fact.
    private func inputDebugLog(_ line: String) {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return }
        let url = directory.appendingPathComponent("input-debug.log")
        let stamped = "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
    }

    // MARK: - Transport

    func togglePlayStop() {
        mode == .stopped ? play() : stop()
    }

    func play() {
        guard mode == .stopped else { return }
        startRolling()
    }

    /// Global stop: finish any recording, stop all clips and the clock.
    func stop() {
        recordAutoStopTask?.cancel()
        recordAutoStopTask = nil
        metronome.setClickSuppressed(false)
        if recordingSlot != nil {
            captureRecordedClip()
            recordingSlot = nil
            recordQueuedUntilBeat = nil
        }
        overdubSource = nil
        recordBarsOverride = nil
        replaceClearPending = false
        for channel in channels.values {
            channel.pendingTask?.cancel()
            channel.pendingTask = nil
            channel.stopAllPlayers()
        }
        playback = [:]
        metronome.stop()
        mode = .stopped
    }

    /// Starts the clock rolling (no clips) and returns the beat-zero anchor.
    @discardableResult
    private func startRolling() -> UInt64 {
        ensureEngineRunning()
        activeCountInBeats = 0
        let anchor = HostClock.now + HostClock.ticks(forSeconds: 0.1)
        metronome.start(countInBeats: 0, atHostTime: anchor)
        mode = .playing
        return anchor
    }

    // MARK: - Clip launching

    func launch(clip: Clip, on track: Track) {
        if recordingSlot != nil { return }
        selectTrack(track)
        if mode == .stopped {
            let anchor = startRolling()
            scheduleLaunch(clip: clip, on: track, boundary: 0, hostTime: anchor)
        } else {
            let boundary = nextQuantizedBeat()
            scheduleLaunch(clip: clip, on: track, boundary: boundary,
                           hostTime: hostTime(forBeat: boundary))
        }
    }

    func stopClip(on track: Track) {
        selectTrack(track)
        guard mode != .stopped,
              let state = playback[track.id],
              state.playingClipID != nil || state.queuedClipID != nil else { return }
        scheduleStop(on: track, boundary: nextQuantizedBeat())
    }

    func launchScene(_ scene: Int) {
        selectScene(scene)
        if recordingSlot != nil { return }
        let clips = tracks.map { $0.slots[scene] }
        guard clips.contains(where: { $0 != nil }) || mode != .stopped else { return }

        let boundary: Double
        let host: UInt64
        if mode == .stopped {
            host = startRolling()
            boundary = 0
        } else {
            boundary = nextQuantizedBeat()
            host = hostTime(forBeat: boundary)
        }

        for (track, clip) in zip(tracks, clips) {
            if let clip {
                scheduleLaunch(clip: clip, on: track, boundary: boundary, hostTime: host)
            } else if let state = playback[track.id],
                      state.playingClipID != nil || state.queuedClipID != nil {
                scheduleStop(on: track, boundary: boundary)
            }
        }
    }

    func stopAllClips() {
        guard mode != .stopped else { return }
        let boundary = nextQuantizedBeat()
        for track in tracks {
            if let state = playback[track.id],
               state.playingClipID != nil || state.queuedClipID != nil {
                scheduleStop(on: track, boundary: boundary)
            }
        }
    }

    private func scheduleLaunch(clip: Clip, on track: Track, boundary: Double, hostTime: UInt64) {
        guard let channel = channels[track.id] else { return }

        let idleIndex = 1 - channel.activeIndex
        let player = channel.players[idleIndex]
        player.stop()
        player.scheduleBuffer(clip.buffer, at: nil, options: [.loops])
        player.play(at: AVAudioTime(hostTime: hostTime))

        var state = playback[track.id] ?? TrackPlayback()
        state.queuedClipID = clip.id
        state.stopQueued = false
        playback[track.id] = state

        let trackID = track.id
        let clipID = clip.id
        channel.pendingTask?.cancel()
        channel.pendingTask = Task { [weak self] in
            await self?.sleep(untilBeat: boundary)
            guard let self, !Task.isCancelled else { return }
            channel.players[channel.activeIndex].stop()
            channel.activeIndex = idleIndex
            var state = self.playback[trackID] ?? TrackPlayback()
            state.playingClipID = clipID
            state.playingStartBeat = boundary
            state.queuedClipID = nil
            self.playback[trackID] = state
        }
    }

    private func scheduleStop(on track: Track, boundary: Double) {
        guard let channel = channels[track.id] else { return }
        var state = playback[track.id] ?? TrackPlayback()
        state.stopQueued = true
        state.queuedClipID = nil
        playback[track.id] = state

        let trackID = track.id
        channel.pendingTask?.cancel()
        channel.pendingTask = Task { [weak self] in
            await self?.sleep(untilBeat: boundary)
            guard let self, !Task.isCancelled else { return }
            channel.stopAllPlayers()
            self.playback[trackID] = TrackPlayback()
        }
    }

    /// Starts a clip immediately but phase-aligned as though it had launched
    /// at `loopStartBeat`: the first pass plays from the current in-loop
    /// offset, then the full buffer loops.
    private func launchInProgress(clip: Clip, on track: Track, loopStartBeat: Double) {
        guard let channel = channels[track.id] else { return }
        let loopBeats = Double(clip.loopBars * beatsPerBar)
        guard loopBeats > 0 else { return }
        let framesPerBeat = 60.0 / tempo * standardFormat.sampleRate
        let startDelay = 0.06
        let beatsAtStart = currentBeats + startDelay * tempo / 60
        var offsetBeats = (beatsAtStart - loopStartBeat).truncatingRemainder(dividingBy: loopBeats)
        if offsetBeats < 0 { offsetBeats += loopBeats }
        let clipFrames = Int(clip.buffer.frameLength)
        let offsetFrames = min(clipFrames, Int((offsetBeats * framesPerBeat).rounded()))

        let idleIndex = 1 - channel.activeIndex
        let player = channel.players[idleIndex]
        player.stop()
        if offsetFrames > 0, offsetFrames < clipFrames,
           let tail = AudioUtil.slice(clip.buffer, from: offsetFrames, frames: clipFrames - offsetFrames) {
            player.scheduleBuffer(tail, at: nil)
        }
        player.scheduleBuffer(clip.buffer, at: nil, options: [.loops])
        player.play(at: AVAudioTime(hostTime: HostClock.now + HostClock.ticks(forSeconds: startDelay)))

        channel.pendingTask?.cancel()
        channel.players[channel.activeIndex].stop()
        channel.activeIndex = idleIndex
        playback[track.id] = TrackPlayback(playingClipID: clip.id,
                                           playingStartBeat: loopStartBeat,
                                           queuedClipID: nil, stopQueued: false)
    }

    // MARK: - Recording

    /// Recording is only possible when the currently selected track is armed.
    var canRecord: Bool {
        recordingSlot == nil && (selectedTrack?.isArmed ?? false)
    }

    /// R key / record button: record into the selected track. Only available
    /// when the selected track is armed. Targets the selected cell on that
    /// track, or its first empty slot if no cell on it is selected.
    func record() {
        guard recordingSlot == nil else { return }
        guard let track = selectedTrack, track.isArmed else {
            statusMessage = "Arm the selected track (● in its header) to record."
            return
        }
        let scene: Int
        if let slot = selectedSlot, slot.trackID == track.id, slot.scene < track.slots.count {
            scene = slot.scene
        } else if let firstEmpty = track.slots.firstIndex(where: { $0 == nil }) {
            scene = firstEmpty
        } else {
            statusMessage = "No empty slot on \(track.name) — select a clip to overwrite or overdub."
            return
        }
        recordIntoSlot(track, scene: scene)
    }

    /// Records into a cell. Empty → new clip. Occupied → overdub (layer) or
    /// replace, per the track's `isOverdub` setting.
    func recordIntoSlot(_ track: Track, scene: Int) {
        selectTrack(track)
        selectedSlot = SlotRef(trackID: track.id, scene: scene)
        guard track.isArmed else {
            statusMessage = "Arm the track first (● in its header)."
            return
        }
        guard recordingSlot == nil else { return }

        let existing = track.slots[scene]
        if let existing, track.isOverdub {
            overdubSource = existing
            recordBarsOverride = existing.loopBars
        } else {
            overdubSource = nil
            recordBarsOverride = nil
            // Replacing an occupied slot: silence the outgoing clip now, and
            // clear it from the slot when recording actually begins.
            if existing != nil {
                stopTrackPlayback(track)
                replaceClearPending = true
            }
        }

        if mode == .stopped {
            Task { await startRecordingFromStopped(track, scene: scene) }
        } else {
            startRecordingWhileRolling(track, scene: scene)
        }
    }

    private func stopTrackPlayback(_ track: Track) {
        guard let channel = channels[track.id] else { return }
        channel.pendingTask?.cancel()
        channel.pendingTask = nil
        channel.stopAllPlayers()
        playback[track.id] = TrackPlayback()
    }

    /// Loops `clip` starting exactly at `host` for overdub monitoring, so the
    /// performer hears the existing take while recording the new layer.
    private func startMonitorPlayback(_ clip: Clip, on track: Track, atHost host: UInt64) {
        guard let channel = channels[track.id] else { return }
        let index = channel.activeIndex
        let player = channel.players[index]
        player.stop()
        player.scheduleBuffer(clip.buffer, at: nil, options: [.loops])
        player.play(at: AVAudioTime(hostTime: host))
    }

    /// Clicking the recording cell: finish the take and relaunch it, with the
    /// transport still rolling — the session-view jam loop.
    func finishRecordingAndPlay() {
        guard let slot = recordingSlot else { return }
        recordAutoStopTask?.cancel()
        recordAutoStopTask = nil
        metronome.setClickSuppressed(false)
        let clip = captureRecordedClip()
        recordingSlot = nil
        recordQueuedUntilBeat = nil
        mode = .playing
        if let clip, let track = tracks.first(where: { $0.id == slot.trackID }) {
            launch(clip: clip, on: track)
        }
    }

    /// Fixed-length recording reached its end bar: capture the take and keep
    /// it sounding without a gap, phase-aligned to the boundary it ended on.
    private func autoFinishRecording(loopStartBeat: Double) {
        guard let slot = recordingSlot else { return }
        metronome.setClickSuppressed(false)
        let clip = captureRecordedClip()
        recordingSlot = nil
        recordQueuedUntilBeat = nil
        mode = .playing
        guard let clip, let track = tracks.first(where: { $0.id == slot.trackID }) else { return }
        launchInProgress(clip: clip, on: track, loopStartBeat: loopStartBeat)
    }

    private func scheduleRecordAutoStop() {
        recordAutoStopTask?.cancel()
        recordAutoStopTask = nil
        // Overdub always runs for the source clip's length; otherwise the
        // REC BARS setting (nil = free, no auto-stop).
        guard let bars = recordBarsOverride ?? recordLengthBars else { return }
        let endBeat = recordStartBeat + Double(bars * beatsPerBar)
        recordAutoStopTask = Task { [weak self] in
            guard let self else { return }
            // Wake just past the boundary so the floor-to-bars trim lands
            // exactly on `bars`.
            await self.sleep(untilBeat: endBeat + 0.02 * self.tempo / 60)
            guard !Task.isCancelled, self.recordingSlot != nil else { return }
            self.autoFinishRecording(loopStartBeat: endBeat)
        }
    }

    private func startRecordingFromStopped(_ track: Track, scene: Int) async {
        guard await AVAudioApplication.requestRecordPermission() else {
            engineError = "Microphone access denied — enable it in System Settings › Privacy & Security › Microphone."
            return
        }
        guard mode == .stopped, recordingSlot == nil else { return }

        if !inputConfigured {
            await configureInput()
            guard inputConfigured else { return }
        }
        ensureEngineRunning()
        recorder.beginCapture()

        engineError = nil
        statusMessage = nil
        recordTempo = tempo
        recordStartBeat = 0
        activeCountInBeats = countInBars * beatsPerBar

        let anchor = HostClock.now + HostClock.ticks(forSeconds: 0.1)
        let countInSeconds = Double(activeCountInBeats) * 60.0 / recordTempo
        beat0Host = anchor + HostClock.ticks(forSeconds: countInSeconds)
        metronome.start(countInBeats: activeCountInBeats, atHostTime: anchor)
        if let source = overdubSource {
            startMonitorPlayback(source, on: track, atHost: beat0Host)
        }
        recordingSlot = SlotRef(trackID: track.id, scene: scene)
        mode = .recording
        metronome.setClickSuppressed(true)
        scheduleRecordAutoStop()
        scheduleReplaceClear(atBeat: recordStartBeat)
    }

    private func startRecordingWhileRolling(_ track: Track, scene: Int) {
        guard inputConfigured else {
            statusMessage = "Stop the transport and re-arm the track to set up the input first."
            return
        }
        recorder.beginCapture()
        statusMessage = nil
        recordTempo = tempo

        // Punch in at the next bar regardless of the launch quantise setting.
        let boundary = Double(beatsPerBar) * ((currentBeats + 0.05 * tempo / 60) / Double(beatsPerBar)).rounded(.up)
        recordStartBeat = boundary
        beat0Host = hostTime(forBeat: boundary)
        if let source = overdubSource {
            startMonitorPlayback(source, on: track, atHost: beat0Host)
        }
        recordingSlot = SlotRef(trackID: track.id, scene: scene)
        recordQueuedUntilBeat = boundary
        mode = .recording
        metronome.setClickSuppressed(true)
        scheduleRecordAutoStop()
        scheduleReplaceClear(atBeat: boundary)

        Task { [weak self] in
            await self?.sleep(untilBeat: boundary)
            guard let self else { return }
            if self.recordQueuedUntilBeat == boundary { self.recordQueuedUntilBeat = nil }
        }
    }

    /// Clears a Replace-mode target clip from its slot the moment recording
    /// actually starts (after count-in / at punch-in), so it isn't left
    /// sitting there during the take. Cancelling during count-in keeps it.
    private func scheduleReplaceClear(atBeat beat: Double) {
        guard replaceClearPending, let slot = recordingSlot else { return }
        replaceClearPending = false
        Task { [weak self] in
            await self?.sleep(untilBeat: beat)
            guard let self, self.recordingSlot == slot,
                  let track = self.tracks.first(where: { $0.id == slot.trackID }),
                  slot.scene < track.slots.count else { return }
            track.slots[slot.scene] = nil
        }
    }

    /// Trims the capture to whole bars from beat zero and drops it into the
    /// recording slot. Returns the new clip, or nil if the take was too short.
    @discardableResult
    private func captureRecordedClip() -> Clip? {
        guard let slot = recordingSlot else { return nil }
        recorder.endCapture()

        let source = overdubSource
        overdubSource = nil
        let barsOverride = recordBarsOverride
        recordBarsOverride = nil

        // Anything captured past the count-in becomes a clip. Overdub and
        // fixed-length both yield an exact bar count (silence-padded if the
        // take was cut short); free mode rounds up to whole bars.
        let beatsRecorded = currentBeats - recordStartBeat
        let bars: Int
        if let fixed = barsOverride ?? recordLengthBars {
            bars = fixed
        } else {
            bars = max(1, Int(((beatsRecorded + 0.05) / Double(beatsPerBar)).rounded(.up)))
        }
        guard beatsRecorded > 0.05,
              let format = recorder.captureFormat,
              let track = tracks.first(where: { $0.id == slot.trackID }) else {
            recorder.discard()
            statusMessage = "Recording stopped during the count-in — discarded."
            return nil
        }

        let framesPerBeat = 60.0 / recordTempo * format.sampleRate
        let frameCount = AVAudioFrameCount((Double(bars * beatsPerBar) * framesPerBeat).rounded())
        guard let captured = recorder.makeLoopBuffer(beat0Host: beat0Host, frameCount: frameCount),
              let takeBuffer = AudioUtil.convert(captured, to: standardFormat) else {
            statusMessage = "Recording failed — no audio was captured."
            return nil
        }

        // Overdub: sum the new take onto the existing clip (same length).
        let buffer: AVAudioPCMBuffer
        let name: String
        let colorIndex: Int
        let loopBars: Int
        if let source, let mixed = AudioUtil.mix(base: source.buffer, overlay: takeBuffer) {
            buffer = mixed
            name = source.name
            colorIndex = source.colorIndex
            loopBars = source.loopBars
            statusMessage = "Overdubbed \(source.name)."
        } else {
            buffer = takeBuffer
            name = "\(track.name) \(slot.scene + 1)"
            colorIndex = track.colorIndex
            loopBars = bars
            statusMessage = nil
        }

        let url = recorder.writeFile(buffer: buffer, name: name)
        let clip = Clip(name: name, colorIndex: colorIndex, buffer: buffer,
                        loopBars: loopBars, fileURL: url)
        track.slots[slot.scene] = clip
        markDirty()
        return clip
    }

    // MARK: - Clip management

    /// DEL key / Track menu: delete the last-clicked clip.
    func deleteSelectedClip() {
        guard let slot = selectedSlot,
              let track = tracks.first(where: { $0.id == slot.trackID }),
              slot.scene < track.slots.count, track.slots[slot.scene] != nil else { return }
        deleteClip(on: track, scene: slot.scene)
    }

    func deleteClip(on track: Track, scene: Int) {
        guard let clip = track.slots[scene] else { return }
        if recordingSlot == SlotRef(trackID: track.id, scene: scene) { return }
        if selectedSlot == SlotRef(trackID: track.id, scene: scene) { selectedSlot = nil }
        if let state = playback[track.id],
           state.playingClipID == clip.id || state.queuedClipID == clip.id,
           let channel = channels[track.id] {
            channel.pendingTask?.cancel()
            channel.stopAllPlayers()
            playback[track.id] = TrackPlayback()
        }
        track.slots[scene] = nil
        markDirty()
        registerUndo("Delete Clip") { engine in
            guard scene < track.slots.count, track.slots[scene] == nil else { return }
            track.slots[scene] = clip
            engine.markDirty()
            engine.registerUndo("Delete Clip") { $0.deleteClip(on: track, scene: scene) }
        }
    }

    func moveClip(from source: SlotRef, to destination: SlotRef) {
        guard source != destination,
              let sourceTrack = tracks.first(where: { $0.id == source.trackID }),
              let destinationTrack = tracks.first(where: { $0.id == destination.trackID }),
              recordingSlot != source, recordingSlot != destination else { return }
        let moving = sourceTrack.slots[source.scene]
        sourceTrack.slots[source.scene] = destinationTrack.slots[destination.scene]
        destinationTrack.slots[destination.scene] = moving
        markDirty()
        registerUndo("Move Clip") { $0.moveClip(from: destination, to: source) }
    }

    func handleClipDropPayload(_ payload: String, destination: SlotRef) {
        let parts = payload.split(separator: ":")
        guard parts.count == 3, parts[0] == "clipmove",
              let trackID = UUID(uuidString: String(parts[1])),
              let scene = Int(parts[2]) else { return }
        moveClip(from: SlotRef(trackID: trackID, scene: scene), to: destination)
    }

    func importAudioFile(_ url: URL, into track: Track, scene: Int) {
        guard recordingSlot == nil else { return }
        guard let clip = makeClip(fromFile: url, colorIndex: track.colorIndex) else { return }
        if track.slots[scene] != nil { deleteClip(on: track, scene: scene) }
        track.slots[scene] = clip
        markDirty()
    }

    private func makeClip(fromFile url: URL, colorIndex: Int) -> Clip? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0,
                  let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(file.length)) else {
                throw NSError(domain: "Stringstack", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Empty or unreadable audio file"])
            }
            try file.read(into: raw)
            guard let buffer = AudioUtil.convert(raw, to: standardFormat) else {
                throw NSError(domain: "Stringstack", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format"])
            }

            let seconds = Double(file.length) / file.processingFormat.sampleRate
            let beats = seconds * tempo / 60
            let bars = max(1, Int((beats / Double(beatsPerBar)).rounded()))
            statusMessage = nil
            return Clip(name: url.deletingPathExtension().lastPathComponent,
                        colorIndex: colorIndex, buffer: buffer, loopBars: bars, fileURL: url)
        } catch {
            statusMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    func allClips() -> [Clip] {
        var seen = Set<UUID>()
        var result: [Clip] = []
        for clip in tracks.flatMap({ $0.slots.compactMap { $0 } })
        where seen.insert(clip.id).inserted {
            result.append(clip)
        }
        return result
    }

    // MARK: - Project load support

    /// Tears down the session and rebuilds it from decoded project state.
    func replaceSession(tempo: Double, beatsPerBar: Int, countInBars: Int,
                        quantize: LaunchQuantize, sceneCount: Int,
                        masterVolume: Double, newTracks: [Track]) {
        stop()
        suppressDirty = true
        defer { suppressDirty = false; hasUnsavedChanges = false }
        for track in tracks { deleteTrack(track) }
        self.tempo = tempo
        self.beatsPerBar = beatsPerBar
        self.countInBars = countInBars
        self.quantize = quantize
        self.sceneCount = sceneCount
        self.masterVolume = masterVolume
        for track in newTracks {
            let channel = TrackChannel()
            audioEngine.attach(channel.mixer)
            audioEngine.attach(channel.players[0])
            audioEngine.attach(channel.players[1])
            audioEngine.attach(channel.inputMixer)
            audioEngine.connect(channel.players[0], to: channel.inputMixer, format: standardFormat)
            audioEngine.connect(channel.players[1], to: channel.inputMixer, format: standardFormat)
            audioEngine.connect(channel.inputMixer, to: channel.mixer, format: standardFormat)
            audioEngine.connect(channel.mixer, to: audioEngine.mainMixerNode, format: nil)
            channel.meter.install(on: channel.mixer)
            channels[track.id] = channel
            tracks.append(track)
        }
        selectedTrackID = tracks.first?.id
        selectedSlot = nil
        selectedScene = sceneCount > 0 ? 0 : nil
        applyMixAll()
    }

    /// Resets to a fresh, empty 4-track / 4-scene project at defaults.
    func newProject() {
        let fresh = (0..<4).map {
            Track(name: "Track \($0 + 1)", colorIndex: $0 % 6, sceneCount: 4)
        }
        replaceSession(tempo: 120, beatsPerBar: 4, countInBars: 2, quantize: .bar,
                       sceneCount: 4, masterVolume: 0.9, newTracks: fresh)
        projectURL = nil
        statusMessage = "New project."
    }

    // MARK: - Beat/time mapping

    /// Next launch boundary in beats, always slightly in the future so the
    /// player start remains schedulable.
    private func nextQuantizedBeat() -> Double {
        let lead = 0.05 * tempo / 60
        let beats = max(0, currentBeats) + lead
        switch quantize {
        case .none: return beats
        case .beat: return beats.rounded(.up)
        case .bar: return Double(beatsPerBar) * (beats / Double(beatsPerBar)).rounded(.up)
        }
    }

    /// Approximate host time of a future beat, assuming the tempo holds
    /// between now and then (tempo changes mid-wait shift queued launches
    /// slightly; the next launch resyncs).
    private func hostTime(forBeat beat: Double) -> UInt64 {
        let seconds = max(0.02, (beat - currentBeats) * 60.0 / tempo)
        return HostClock.now + HostClock.ticks(forSeconds: seconds)
    }

    /// Sleeps until the transport clock has actually reached `beat`. The
    /// clock starts on a future anchor, so a single duration computed up
    /// front wakes early — this loops against the authoritative clock (and
    /// self-corrects across tempo changes).
    private func sleep(untilBeat beat: Double) async {
        while !Task.isCancelled, currentBeats < beat {
            if mode == .stopped { return }
            let seconds = max(0.002, (beat - currentBeats) * 60.0 / tempo)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    // MARK: - Devices

    private func handleDeviceListChange() {
        guard mode == .recording,
              !devices.inputDevices.contains(where: { $0.id == devices.selectedDeviceID })
        else { return }
        // The device we were capturing from disappeared: keep what we have.
        stop()
        recorder.removeTap(from: audioEngine.inputNode)
        inputConfigured = false
        statusMessage = "Input device disconnected — recording stopped."
    }

    // MARK: - Engine lifecycle

    private func startEngine() {
        do {
            try audioEngine.start()
            engineError = nil
        } catch {
            engineError = "Audio engine failed to start: \(error.localizedDescription)"
        }
    }

    private func ensureEngineRunning() {
        if !audioEngine.isRunning { startEngine() }
    }
}
