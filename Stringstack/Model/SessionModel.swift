import AVFoundation
import Observation

/// A track: a column in the session grid. Holds no audio nodes — the engine
/// keeps a `TrackChannel` per track, keyed by `id`.
@MainActor
@Observable
final class Track: Identifiable {
    let id = UUID()
    var name: String
    var colorIndex: Int
    var isArmed = false
    var isMuted = false
    var isSoloed = false
    var volume = 0.8
    var pan = 0.0
    var slots: [Clip?]
    /// Insert-effect chain, processed in order between the track's players
    /// and its fader mixer.
    var effects: [EffectInstance] = []

    init(name: String, colorIndex: Int, sceneCount: Int) {
        self.name = name
        self.colorIndex = colorIndex
        self.slots = Array(repeating: nil, count: sceneCount)
    }
}

/// An audio loop living in a session grid slot. Buffers are normalised to
/// the engine's standard format at creation so any clip can play on any
/// track player.
@MainActor
@Observable
final class Clip: Identifiable {
    let id: UUID
    var name: String
    /// Index into `Theme.trackPalette` — the model stays UI-free.
    var colorIndex: Int
    let buffer: AVAudioPCMBuffer
    let loopBars: Int
    let fileURL: URL?
    /// Low-res peaks for grid cells and placements.
    let waveform: [Float]
    /// High-res peaks for the clip inspector.
    let detailWaveform: [Float]

    init(id: UUID = UUID(), name: String, colorIndex: Int, buffer: AVAudioPCMBuffer,
         loopBars: Int, fileURL: URL?) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.buffer = buffer
        self.loopBars = loopBars
        self.fileURL = fileURL
        self.waveform = Waveform.peaks(for: buffer, bins: 96)
        self.detailWaveform = Waveform.peaks(for: buffer, bins: 480)
    }
}

/// A loaded AU effect in a track's device chain.
@MainActor
@Observable
final class EffectInstance: Identifiable {
    let id = UUID()
    let name: String
    let manufacturer: String
    let componentDescription: AudioComponentDescription
    let node: AVAudioUnit

    var isBypassed = false {
        didSet { node.auAudioUnit.shouldBypassEffect = isBypassed }
    }

    init(name: String, manufacturer: String,
         componentDescription: AudioComponentDescription, node: AVAudioUnit) {
        self.name = name
        self.manufacturer = manufacturer
        self.componentDescription = componentDescription
        self.node = node
    }
}

/// Addresses one cell in the session grid.
struct SlotRef: Hashable {
    let trackID: UUID
    let scene: Int
}

/// Launch quantisation for session clips.
enum LaunchQuantize: String, CaseIterable, Identifiable {
    case none = "None"
    case beat = "1 Beat"
    case bar = "1 Bar"
    var id: String { rawValue }
}

/// Per-track playback state published for the grid UI.
struct TrackPlayback: Equatable {
    var playingClipID: UUID?
    var playingStartBeat = 0.0
    var queuedClipID: UUID?
    var stopQueued = false
}
