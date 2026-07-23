import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// Reads and writes `.stringstackproj` bundles: a folder containing
/// `project.json` plus an `Audio/` directory with one CAF per clip.
enum ProjectStore {

    static let projectType = UTType(exportedAs: "com.stringstack.project")

    // MARK: - Codable schema

    struct ProjectData: Codable {
        var version = 1
        var tempo: Double
        var beatsPerBar: Int
        var countInBars: Int
        var quantize: String
        var sceneCount: Int
        /// Legacy (arrangement view removed) — kept for file compatibility.
        var playheadBar: Int = 0
        var masterVolume: Double
        var clips: [ClipData]
        var tracks: [TrackData]
    }

    struct ClipData: Codable {
        var id: UUID
        var name: String
        var colorIndex: Int
        var loopBars: Int
        var audioFile: String
    }

    /// Legacy (arrangement view removed) — kept so old files still decode.
    struct PlacementData: Codable {
        var id: UUID
        var clipID: UUID
        var startBar: Int
        var lengthBars: Int
    }

    struct TrackData: Codable {
        var name: String
        var colorIndex: Int
        var volume: Double
        var pan: Double
        var isMuted: Bool
        var isSoloed: Bool
        var isOverdub: Bool?
        var slots: [UUID?]
        var placements: [PlacementData]?
        var effects: [EffectData]?
    }

    struct EffectData: Codable {
        var name: String
        var manufacturer: String
        var componentType: UInt32
        var componentSubType: UInt32
        var componentManufacturer: UInt32
        var isBypassed: Bool
        var state: Data?
    }

    // MARK: - Panels

    @MainActor
    static func saveWithPanel(engine: TransportEngine) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [projectType]
        panel.nameFieldStringValue = "Untitled"
        panel.title = "Save Stringstack Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try write(engine: engine, to: url)
            engine.projectURL = url
            engine.statusMessage = "Saved \(url.lastPathComponent)"
        } catch {
            engine.engineError = "Couldn't save project: \(error.localizedDescription)"
        }
    }

    @MainActor
    static func openWithPanel(engine: TransportEngine) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [projectType]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Open Stringstack Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try read(into: engine, from: url)
            engine.projectURL = url
            engine.statusMessage = "Opened \(url.lastPathComponent)"
        } catch {
            engine.engineError = "Couldn't open project: \(error.localizedDescription)"
        }
    }

    // MARK: - Writing

    @MainActor
    static func write(engine: TransportEngine, to url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        let audioDirectory = url.appendingPathComponent("Audio", isDirectory: true)
        try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        var clipDatas: [ClipData] = []
        for clip in engine.allClips() {
            let filename = "\(clip.id.uuidString).caf"
            let file = try AVAudioFile(forWriting: audioDirectory.appendingPathComponent(filename),
                                       settings: clip.buffer.format.settings)
            try file.write(from: clip.buffer)
            clipDatas.append(ClipData(id: clip.id, name: clip.name, colorIndex: clip.colorIndex,
                                      loopBars: clip.loopBars, audioFile: filename))
        }

        let trackDatas = engine.tracks.map { track in
            TrackData(name: track.name, colorIndex: track.colorIndex,
                      volume: track.volume, pan: track.pan,
                      isMuted: track.isMuted, isSoloed: track.isSoloed,
                      isOverdub: track.isOverdub,
                      slots: track.slots.map { $0?.id },
                      placements: nil,
                      effects: track.effects.map { effect in
                          var state: Data?
                          if let fullState = effect.node.auAudioUnit.fullState {
                              state = try? NSKeyedArchiver.archivedData(
                                  withRootObject: fullState, requiringSecureCoding: false)
                          }
                          return EffectData(name: effect.name,
                                            manufacturer: effect.manufacturer,
                                            componentType: effect.componentDescription.componentType,
                                            componentSubType: effect.componentDescription.componentSubType,
                                            componentManufacturer: effect.componentDescription.componentManufacturer,
                                            isBypassed: effect.isBypassed,
                                            state: state)
                      })
        }

        let project = ProjectData(tempo: engine.tempo, beatsPerBar: engine.beatsPerBar,
                                  countInBars: engine.countInBars,
                                  quantize: engine.quantize.rawValue,
                                  sceneCount: engine.sceneCount,
                                  masterVolume: engine.masterVolume,
                                  clips: clipDatas, tracks: trackDatas)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: url.appendingPathComponent("project.json"))
        engine.markSaved()
    }

    // MARK: - New project

    /// New Project, guarding unsaved changes: prompts Save / Don't Save /
    /// Cancel first. Returns without resetting if the user cancels (or
    /// cancels the save panel for an untitled project).
    @MainActor
    static func newProjectWithPrompt(engine: TransportEngine) {
        guard engine.hasUnsavedChanges else {
            engine.newProject()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save changes before starting a new project?"
        alert.informativeText = "Your current changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            engine.saveInPlace()
            // If saving went through a panel that was cancelled, the project
            // is still dirty — abort rather than discarding the work.
            guard !engine.hasUnsavedChanges else { return }
            engine.newProject()
        case .alertSecondButtonReturn:
            engine.newProject()
        default:
            break
        }
    }

    // MARK: - Reading

    @MainActor
    static func read(into engine: TransportEngine, from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url.appendingPathComponent("project.json"))
        let project = try JSONDecoder().decode(ProjectData.self, from: data)

        var clipsByID: [UUID: Clip] = [:]
        for clipData in project.clips {
            let audioURL = url.appendingPathComponent("Audio/\(clipData.audioFile)")
            let file = try AVAudioFile(forReading: audioURL)
            guard file.length > 0,
                  let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(file.length)) else { continue }
            try file.read(into: raw)
            guard let buffer = AudioUtil.convert(raw, to: engine.standardFormat) else { continue }
            clipsByID[clipData.id] = Clip(id: clipData.id, name: clipData.name,
                                          colorIndex: clipData.colorIndex, buffer: buffer,
                                          loopBars: clipData.loopBars, fileURL: audioURL)
        }

        var newTracks: [Track] = []
        for trackData in project.tracks {
            let track = Track(name: trackData.name, colorIndex: trackData.colorIndex,
                              sceneCount: project.sceneCount)
            track.volume = trackData.volume
            track.pan = trackData.pan
            track.isMuted = trackData.isMuted
            track.isSoloed = trackData.isSoloed
            track.isOverdub = trackData.isOverdub ?? false
            var slots: [Clip?] = trackData.slots.map { $0.flatMap { clipsByID[$0] } }
            while slots.count < project.sceneCount { slots.append(nil) }
            track.slots = Array(slots.prefix(project.sceneCount))
            newTracks.append(track)
        }

        engine.replaceSession(tempo: project.tempo, beatsPerBar: project.beatsPerBar,
                              countInBars: project.countInBars,
                              quantize: LaunchQuantize(rawValue: project.quantize) ?? .bar,
                              sceneCount: project.sceneCount,
                              masterVolume: project.masterVolume,
                              newTracks: newTracks)

        // Effects load asynchronously (AU instantiation is async); chains
        // rebuild as each one lands, preserving saved order.
        Task { @MainActor in
            for (index, trackData) in project.tracks.enumerated() where index < engine.tracks.count {
                for effectData in trackData.effects ?? [] {
                    let description = AudioComponentDescription(
                        componentType: effectData.componentType,
                        componentSubType: effectData.componentSubType,
                        componentManufacturer: effectData.componentManufacturer,
                        componentFlags: 0, componentFlagsMask: 0)
                    await engine.restoreEffect(name: effectData.name,
                                               manufacturer: effectData.manufacturer,
                                               description: description,
                                               state: effectData.state,
                                               bypassed: effectData.isBypassed,
                                               on: engine.tracks[index])
                }
            }
        }
    }
}
