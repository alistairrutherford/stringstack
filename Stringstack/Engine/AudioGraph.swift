import AVFoundation

/// Owns the AVAudioEngine node graph: the master mixer, one channel strip per
/// track (players → input mixer → [effects] → fader/pan mixer → master), the
/// metronome/output source, master metering, and engine lifecycle.
///
/// This keeps every raw AVAudioEngine call out of the transport coordinator —
/// `TransportEngine` asks the graph to add/remove channels, set mix values,
/// (re)wire effect chains, and start/stop, without touching nodes directly.
@MainActor
final class AudioGraph {
    let engine = AVAudioEngine()
    /// All clip buffers are normalised to this, so any clip plays on any of
    /// the permanently-connected track players.
    let standardFormat: AVAudioFormat
    let masterMeter = MeterTap()

    private(set) var channels: [UUID: TrackChannel] = [:]
    /// Non-nil after a failed `start()`; surfaced by the coordinator.
    private(set) var startError: String?

    init() {
        var sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0 { sampleRate = 44100 }
        standardFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }

    var sampleRate: Double { standardFormat.sampleRate }
    var inputNode: AVAudioInputNode { engine.inputNode }
    var isRunning: Bool { engine.isRunning }
    /// On macOS the engine's input and output can share one HAL I/O unit.
    var sharesIOUnit: Bool {
        inputNode.audioUnit != nil && inputNode.audioUnit == engine.outputNode.audioUnit
    }

    // MARK: - Lifecycle

    /// Starts the engine, capturing any failure. Returns the error message
    /// (nil on success) so the coordinator can surface it.
    @discardableResult
    func start() -> String? {
        do {
            try engine.start()
            startError = nil
        } catch {
            startError = "Audio engine failed to start: \(error.localizedDescription)"
        }
        return startError
    }

    /// Starts the engine, rethrowing — used by input bring-up, which needs to
    /// react to a failure and retry.
    func startThrowing() throws { try engine.start() }

    func ensureRunning() { if !engine.isRunning { start() } }
    func stop() { engine.stop() }
    func reset() { engine.reset() }
    func prepare() { engine.prepare() }

    // MARK: - Master / source nodes

    /// Attaches a source (the metronome) straight to the master mixer.
    func attachSource(_ node: AVAudioSourceNode) {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nil)
    }

    func installMasterMeter() { masterMeter.install(on: engine.mainMixerNode) }
    func setMasterVolume(_ volume: Double) { engine.mainMixerNode.outputVolume = Float(volume) }

    // MARK: - Channels

    @discardableResult
    func addChannel(for id: UUID) -> TrackChannel {
        let channel = TrackChannel()
        engine.attach(channel.mixer)
        engine.attach(channel.players[0])
        engine.attach(channel.players[1])
        engine.attach(channel.inputMixer)
        engine.connect(channel.players[0], to: channel.inputMixer, format: standardFormat)
        engine.connect(channel.players[1], to: channel.inputMixer, format: standardFormat)
        engine.connect(channel.inputMixer, to: channel.mixer, format: standardFormat)
        engine.connect(channel.mixer, to: engine.mainMixerNode, format: nil)
        channel.meter.install(on: channel.mixer)
        channels[id] = channel
        return channel
    }

    func removeChannel(for id: UUID) {
        guard let channel = channels[id] else { return }
        channel.pendingTask?.cancel()
        channel.stopAllPlayers()
        channel.mixer.removeTap(onBus: 0)
        engine.detach(channel.players[0])
        engine.detach(channel.players[1])
        engine.detach(channel.inputMixer)
        engine.detach(channel.mixer)
        channels.removeValue(forKey: id)
    }

    func channel(for id: UUID) -> TrackChannel? { channels[id] }

    func setMix(for id: UUID, volume: Double, pan: Double, audible: Bool) {
        guard let channel = channels[id] else { return }
        channel.mixer.outputVolume = audible ? Float(volume) : 0
        channel.mixer.pan = Float(pan)
    }

    func meterLevels(for id: UUID) -> (left: Double, right: Double) {
        channels[id]?.meter.levels ?? (0, 0)
    }

    // MARK: - Effects

    func attachEffect(_ unit: AVAudioUnit) { engine.attach(unit) }
    func detachEffect(_ unit: AVAudioUnit) { engine.detach(unit) }

    /// Reconnects inputMixer → effects… → fader mixer in chain order. Bypass
    /// is handled per-node via `shouldBypassEffect`, so it never rebuilds.
    func rebuildChain(for id: UUID, effects: [EffectInstance]) {
        guard let channel = channels[id] else { return }
        engine.disconnectNodeOutput(channel.inputMixer)
        for effect in effects { engine.disconnectNodeOutput(effect.node) }
        var current: AVAudioNode = channel.inputMixer
        for effect in effects {
            engine.connect(current, to: effect.node, format: standardFormat)
            current = effect.node
        }
        engine.connect(current, to: channel.mixer, format: standardFormat)
    }
}
