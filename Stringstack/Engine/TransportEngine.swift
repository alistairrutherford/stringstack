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

    /// Core Audio input devices; owned by the input controller and exposed
    /// for the input picker UI.
    var devices: DeviceManager { input.devices }

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

    /// Input gain applied to recorded audio (and the input meter). 1 = unity.
    var inputGain = 1.0 {
        didSet { recorder.setInputGain(inputGain) }
    }

    var masterVolume = 0.9 {
        didSet {
            graph.setMasterVolume(masterVolume)
            markDirty()
        }
    }

    /// Total count-in beats of the transport run currently in progress.
    @ObservationIgnored private(set) var activeCountInBeats = 0

    /// The AVAudioEngine node graph (channels, mixing, effects, lifecycle).
    @ObservationIgnored private let graph = AudioGraph()
    @ObservationIgnored private let metronome: MetronomeSource
    @ObservationIgnored private let recorder = RecordingService()
    @ObservationIgnored private let input: AudioInputController
    @ObservationIgnored private var beat0Host: UInt64 = 0
    @ObservationIgnored private var recordTempo: Double = 120
    @ObservationIgnored private var recordStartBeat = 0.0
    @ObservationIgnored private var recordAutoStopTask: Task<Void, Never>?
    /// When recording an overdub, the existing clip being layered onto; its
    /// length also fixes the take length via `recordBarsOverride`.
    @ObservationIgnored private var overdubSource: Clip?
    @ObservationIgnored private var recordBarsOverride: Int?
    /// A Replace-mode take that must clear its slot once recording begins.
    @ObservationIgnored private var replaceClearPending = false

    /// Standard clip format — the graph normalises every buffer to it.
    var standardFormat: AVAudioFormat { graph.standardFormat }
    /// Master output meter, polled by the mixer UI.
    var masterMeter: MeterTap { graph.masterMeter }

    /// Beats since bar 1 started; negative while counting in. Poll, don't observe.
    var currentBeats: Double { metronome.currentBeats }

    var isCountingIn: Bool { mode == .recording && currentBeats < 0 }

    /// Smoothed input level (0...1) while capturing. Poll, don't observe.
    var inputPeak: Double { recorder.inputPeak }

    var armedTrack: Track? { tracks.first { $0.isArmed } }

    init() {
        metronome = MetronomeSource(sampleRate: graph.sampleRate)
        input = AudioInputController(graph: graph, recorder: recorder)

        graph.attachSource(metronome.node)
        graph.setMasterVolume(masterVolume)
        startEngine()
        graph.installMasterMeter()

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
        graph.addChannel(for: track.id)
        tracks.append(track)
        applyMix(track)
        markDirty()
    }

    func deleteTrack(_ track: Track) {
        if recordingSlot?.trackID == track.id { stop() }
        for effect in track.effects {
            PluginWindows.close(effect.id)
            graph.detachEffect(effect.node)
        }
        track.effects.removeAll()
        graph.removeChannel(for: track.id)
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

    /// Inserts an empty scene row at `index`, shifting later rows (and any
    /// anchored selection/recording) down. Does not mark dirty — the caller
    /// does, as part of a larger edit.
    func insertScene(at index: Int) {
        let clamped = max(0, min(index, sceneCount))
        for track in tracks { track.slots.insert(nil, at: clamped) }
        sceneCount += 1
        if let scene = selectedScene, scene >= clamped { selectedScene = scene + 1 }
        if let slot = selectedSlot, slot.scene >= clamped {
            selectedSlot = SlotRef(trackID: slot.trackID, scene: slot.scene + 1)
        }
        if let slot = recordingSlot, slot.scene >= clamped {
            recordingSlot = SlotRef(trackID: slot.trackID, scene: slot.scene + 1)
        }
    }

    /// Reorders a scene row (drag up/down). Every track's slots are permuted
    /// identically; numbering stays consecutive since it's just row index + 1.
    func moveScene(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, source < sceneCount,
              destination >= 0, destination < sceneCount else { return }
        for track in tracks {
            let moved = track.slots.remove(at: source)
            track.slots.insert(moved, at: destination)
        }
        selectedScene = remapSceneIndex(selectedScene, from: source, to: destination)
        if let slot = selectedSlot {
            selectedSlot = SlotRef(trackID: slot.trackID,
                                   scene: remapSceneIndex(slot.scene, from: source, to: destination) ?? slot.scene)
        }
        if let slot = recordingSlot {
            recordingSlot = SlotRef(trackID: slot.trackID,
                                    scene: remapSceneIndex(slot.scene, from: source, to: destination) ?? slot.scene)
        }
        markDirty()
        registerUndo("Move Scene") { $0.moveScene(from: destination, to: source) }
    }

    /// Where a row index ends up after moving `source` to `destination`.
    private func remapSceneIndex(_ index: Int?, from source: Int, to destination: Int) -> Int? {
        guard let index else { return nil }
        if index == source { return destination }
        if source < destination, index > source, index <= destination { return index - 1 }
        if source > destination, index >= destination, index < source { return index + 1 }
        return index
    }

    /// Whether a scene row holds at least one clip (drives the enabled state
    /// of "Duplicate Scene").
    func sceneHasClips(_ scene: Int) -> Bool {
        guard scene >= 0, scene < sceneCount else { return false }
        return tracks.contains { scene < $0.slots.count && $0.slots[scene] != nil }
    }

    /// Right-click a scene number: duplicate the whole row (all its clips)
    /// into a new scene inserted directly below.
    func duplicateScene(_ scene: Int) {
        guard scene >= 0, scene < sceneCount else { return }
        let targetScene = scene + 1
        insertScene(at: targetScene)
        for track in tracks {
            if let clip = track.slots[scene] {
                track.slots[targetScene] = duplicate(of: clip)
            }
        }
        markDirty()
        selectedScene = targetScene
        registerUndo("Duplicate Scene") { engine in
            engine.removeScene(at: targetScene)
            engine.markDirty()
            engine.registerUndo("Duplicate Scene") { $0.duplicateScene(scene) }
        }
    }

    /// Right-click a scene number: delete the whole row (undoable). The grid
    /// can be emptied entirely; add rows again with the + button.
    func deleteScene(_ scene: Int) {
        guard scene >= 0, scene < sceneCount else { return }
        let saved: [(trackID: UUID, clip: Clip)] = tracks.compactMap { track in
            track.slots[scene].map { (track.id, $0) }
        }
        removeScene(at: scene)
        markDirty()
        registerUndo("Delete Scene") { engine in
            engine.insertScene(at: scene)
            for entry in saved {
                if let track = engine.tracks.first(where: { $0.id == entry.trackID }),
                   scene < track.slots.count {
                    track.slots[scene] = entry.clip
                }
            }
            engine.markDirty()
            engine.registerUndo("Delete Scene") { $0.deleteScene(scene) }
        }
    }

    /// Removes the scene row at `index`, stopping any clip playing in it and
    /// shifting later rows up.
    func removeScene(at index: Int) {
        guard index >= 0, index < sceneCount else { return }
        for track in tracks {
            if let clip = track.slots[index],
               let state = playback[track.id],
               state.playingClipID == clip.id || state.queuedClipID == clip.id,
               let channel = graph.channel(for: track.id) {
                channel.pendingTask?.cancel()
                channel.stopAllPlayers()
                playback[track.id] = TrackPlayback()
            }
            track.slots.remove(at: index)
        }
        sceneCount -= 1
        if let scene = selectedScene {
            if scene > index { selectedScene = scene - 1 }
            else if scene == index { selectedScene = sceneCount > 0 ? min(index, sceneCount - 1) : nil }
        }
        if let slot = selectedSlot {
            if slot.scene == index { selectedSlot = nil }
            else if slot.scene > index {
                selectedSlot = SlotRef(trackID: slot.trackID, scene: slot.scene - 1)
            }
        }
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
        graph.meterLevels(for: track.id)
    }

    private func applyMixAll() {
        for track in tracks { applyMix(track) }
    }

    private func applyMix(_ track: Track) {
        let anySolo = tracks.contains { $0.isSoloed }
        let audible = !track.isMuted && (!anySolo || track.isSoloed)
        graph.setMix(for: track.id, volume: track.volume, pan: track.pan, audible: audible)
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
                graph.attachEffect(unit)
                let effect = EffectInstance(name: name, manufacturer: manufacturer,
                                            componentDescription: description, node: unit)
                track.effects.append(effect)
                graph.rebuildChain(for: track.id, effects: track.effects)
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
        graph.rebuildChain(for: track.id, effects: track.effects)
        graph.detachEffect(effect.node)
        markDirty()
    }

    /// Moves an effect one step left (-1) or right (+1) in the chain.
    func moveEffect(_ effect: EffectInstance, in track: Track, by offset: Int) {
        guard let index = track.effects.firstIndex(where: { $0.id == effect.id }) else { return }
        let target = index + offset
        guard target >= 0, target < track.effects.count else { return }
        track.effects.swapAt(index, target)
        graph.rebuildChain(for: track.id, effects: track.effects)
        markDirty()
    }

    /// Re-instantiates a saved effect and applies its archived state.
    func restoreEffect(name: String, manufacturer: String,
                       description: AudioComponentDescription,
                       state: Data?, bypassed: Bool, on track: Track) async {
        do {
            let unit = try await AVAudioUnit.instantiate(with: description, options: [])
            graph.attachEffect(unit)
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
            graph.rebuildChain(for: track.id, effects: track.effects)
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
        if input.isConfigured {
            armOnly(track)
        } else {
            guard mode == .stopped else {
                statusMessage = "Stop the transport before arming for the first time."
                return
            }
            Task {
                let outcome = await input.configure()
                applyConfigureOutcome(outcome, thenArm: track)
            }
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
        guard input.isConfigured else { return }
        if mode == .stopped {
            Task {
                let outcome = await input.configure()
                applyConfigureOutcome(outcome, thenArm: nil)
            }
        } else {
            input.invalidate()
            statusMessage = "Input change applies once the transport stops — re-arm the track."
        }
    }

    /// Translates the input controller's bring-up outcome into UI state and
    /// arms the requested track on success.
    private func applyConfigureOutcome(_ outcome: AudioInputController.ConfigureOutcome,
                                       thenArm track: Track?) {
        switch outcome {
        case .success:
            engineError = nil
            statusMessage = nil
            if let track { armOnly(track) }
        case .successUsingDefault:
            engineError = nil
            statusMessage = "Using the system default input device."
            if let track { armOnly(track) }
        case .permissionDenied:
            engineError = "Microphone access denied — enable it in System Settings › Privacy & Security › Microphone."
        case .failed(let message):
            // Bring the base (output-only) engine back, then surface the error.
            startEngine()
            engineError = message
        }
    }

    // MARK: - Transport

    /// Main Play launches the currently selected scene (or just starts the
    /// transport if no scene is selected); Play again stops.
    func togglePlayStop() {
        if mode == .stopped {
            if let scene = selectedScene {
                launchScene(scene)
            } else {
                play()
            }
        } else {
            stop()
        }
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
        for channel in graph.channels.values {
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
        guard let channel = graph.channel(for: track.id) else { return }

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
        guard let channel = graph.channel(for: track.id) else { return }
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
        guard let channel = graph.channel(for: track.id) else { return }
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
        guard let channel = graph.channel(for: track.id) else { return }
        channel.pendingTask?.cancel()
        channel.pendingTask = nil
        channel.stopAllPlayers()
        playback[track.id] = TrackPlayback()
    }

    /// Loops `clip` starting exactly at `host` for overdub monitoring, so the
    /// performer hears the existing take while recording the new layer.
    private func startMonitorPlayback(_ clip: Clip, on track: Track, atHost host: UInt64) {
        guard let channel = graph.channel(for: track.id) else { return }
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
        guard mode == .stopped, recordingSlot == nil else { return }

        if !input.isConfigured {
            let outcome = await input.configure()
            applyConfigureOutcome(outcome, thenArm: nil)
            guard input.isConfigured else { return }
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
        guard input.isConfigured else {
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

    /// Recolour a clip — routed through the engine so it marks the project
    /// dirty and registers undo, rather than the view mutating the model.
    func setClipColor(_ clip: Clip, colorIndex: Int) {
        guard clip.colorIndex != colorIndex else { return }
        let previous = clip.colorIndex
        clip.colorIndex = colorIndex
        markDirty()
        registerUndo("Recolour Clip") { $0.setClipColor(clip, colorIndex: previous) }
    }

    /// ⌘D / Track menu: duplicate the selected clip into the scene below.
    func duplicateSelectedClip() {
        guard let slot = selectedSlot,
              let track = tracks.first(where: { $0.id == slot.trackID }),
              slot.scene < track.slots.count, let clip = track.slots[slot.scene] else { return }
        duplicateClipDown(clip, on: track, scene: slot.scene)
    }

    /// Duplicates a clip into the scene below on the same track:
    /// - empty slot below → duplicate into it;
    /// - occupied slot below → insert a new scene there and duplicate into it;
    /// - no scene below → append a scene and duplicate into it.
    func duplicateClipDown(_ clip: Clip, on track: Track, scene: Int) {
        guard scene >= 0, scene < track.slots.count, let original = track.slots[scene] else { return }
        let targetScene = scene + 1
        let copy = duplicate(of: original)

        let insertedScene: Bool
        if targetScene >= sceneCount {
            insertScene(at: sceneCount)
            insertedScene = true
        } else if track.slots[targetScene] != nil {
            insertScene(at: targetScene)
            insertedScene = true
        } else {
            insertedScene = false
        }
        track.slots[targetScene] = copy
        markDirty()
        selectTrack(track)
        selectedScene = targetScene
        selectedSlot = SlotRef(trackID: track.id, scene: targetScene)

        registerUndo("Duplicate Clip") { engine in
            if insertedScene {
                engine.removeScene(at: targetScene)
            } else if targetScene < track.slots.count {
                track.slots[targetScene] = nil
            }
            engine.markDirty()
            engine.registerUndo("Duplicate Clip") { redo in
                redo.duplicateClipDown(clip, on: track, scene: scene)
            }
        }
    }

    /// A fresh copy sharing the (immutable) audio buffer, with a new id.
    private func duplicate(of clip: Clip) -> Clip {
        Clip(name: clip.name, colorIndex: clip.colorIndex, buffer: clip.buffer,
             loopBars: clip.loopBars, fileURL: clip.fileURL)
    }

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
           let channel = graph.channel(for: track.id) {
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
            graph.addChannel(for: track.id)
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
        input.teardown()
        statusMessage = "Input device disconnected — recording stopped."
    }

    // MARK: - Engine lifecycle

    private func startEngine() {
        engineError = graph.start()
    }

    private func ensureEngineRunning() {
        graph.ensureRunning()
    }
}
