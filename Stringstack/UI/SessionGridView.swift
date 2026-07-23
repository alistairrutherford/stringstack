import SwiftUI
import UniformTypeIdentifiers

private enum GridMetrics {
    static let cellWidth: CGFloat = 136
    static let cellHeight: CGFloat = 46
    static let headerHeight: CGFloat = 108
    static let sceneWidth: CGFloat = 44
    static let spacing: CGFloat = 7
}

/// The Ableton-style session view: tracks as columns, scenes as rows.
struct SessionGridView: View {
    @Environment(TransportEngine.self) private var engine

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: GridMetrics.spacing + 3) {
                sceneColumn
                ForEach(engine.tracks) { track in
                    TrackColumn(track: track)
                }
                addTrackButton
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Scene launch column

    private var sceneColumn: some View {
        VStack(spacing: GridMetrics.spacing) {
            Text("SCENES")
                .font(.system(size: 9, weight: .heavy))
                .tracking(1.5)
                .foregroundStyle(Theme.dimmed)
                .frame(width: GridMetrics.sceneWidth, height: GridMetrics.headerHeight)

            ForEach(0..<engine.sceneCount, id: \.self) { scene in
                Button {
                    engine.launchScene(scene)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.violet)
                        .frame(width: GridMetrics.sceneWidth, height: GridMetrics.cellHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.surface)
                        )
                }
                .buttonStyle(.plain)
                .help("Launch scene \(scene + 1)")
            }

            Button {
                engine.addScene()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.dimmed)
                    .frame(width: GridMetrics.sceneWidth, height: 26)
            }
            .buttonStyle(.plain)
            .help("Add scene")

            Button {
                engine.stopAllClips()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.coral)
                    .frame(width: GridMetrics.sceneWidth, height: GridMetrics.cellHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.surface)
                    )
            }
            .buttonStyle(.plain)
            .help("Stop all clips")
        }
    }

    private var addTrackButton: some View {
        Button {
            engine.addTrack()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                Text("TRACK")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.5)
            }
            .foregroundStyle(Theme.dimmed)
            .frame(width: 64, height: GridMetrics.headerHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            )
        }
        .buttonStyle(.plain)
        .help("Add track")
    }
}

// MARK: - Track column

private struct TrackColumn: View {
    @Environment(TransportEngine.self) private var engine
    let track: Track

    var body: some View {
        let color = Theme.trackPalette[track.colorIndex % Theme.trackPalette.count]
        let isSelected = engine.selectedTrackID == track.id

        VStack(spacing: GridMetrics.spacing) {
            TrackHeader(track: track)
            ForEach(0..<engine.sceneCount, id: \.self) { scene in
                ClipCell(track: track, scene: scene)
            }
        }
        // Selection reads as a box around the whole column — header and
        // every clip — so it can't be mistaken for keyboard focus.
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isSelected ? color.opacity(0.07) : .clear)
                .padding(-3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isSelected ? color.opacity(0.7) : .clear, lineWidth: 2)
                .padding(-3)
        )
    }
}

private struct TrackHeader: View {
    @Environment(TransportEngine.self) private var engine
    let track: Track

    private var color: Color { Theme.trackPalette[track.colorIndex % Theme.trackPalette.count] }

    var body: some View {
        VStack(spacing: 6) {
            Text(track.name)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                headerButton("record.circle", active: track.isArmed, color: Theme.coral) {
                    engine.toggleArm(track)
                }
                .help("Arm for recording")

                headerButton(track.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                             active: track.isMuted, color: Theme.amber) {
                    engine.toggleMute(track)
                }
                .help(track.isMuted ? "Unmute" : "Mute")

                headerButton("s.square.fill", active: track.isSoloed, color: Theme.cyan) {
                    engine.toggleSolo(track)
                }
                .help("Solo")

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                sliderRow("VOL", value: Binding(
                    get: { track.volume },
                    set: { engine.setVolume(track, $0) }
                ), range: 0...1)
                .help("Track volume")

                PanKnob(color: color, pan: Binding(
                    get: { track.pan },
                    set: { engine.setPan(track, $0) }
                ))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: GridMetrics.cellWidth, height: GridMetrics.headerHeight)
        .background(
            VStack(spacing: 0) {
                Rectangle().fill(color).frame(height: 4)
                Rectangle().fill(Theme.surfaceRaised)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        )
        .contentShape(Rectangle())
        .onTapGesture { engine.selectTrack(track) }
        .contextMenu {
            Button("Delete Track", role: .destructive) { engine.deleteTrack(track) }
        }
        .help("Click to select (FX chain below follows selection)")
    }

    private func headerButton(_ symbol: String, active: Bool, color: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(active ? Color.black.opacity(0.8) : color)
                .frame(width: 26, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? AnyShapeStyle(color) : AnyShapeStyle(Theme.surface))
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func sliderRow(_ label: String, value: Binding<Double>,
                           range: ClosedRange<Double>) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(Theme.dimmed)
                .frame(width: 20, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
                .tint(color)
                .focusable(false)
        }
    }
}

/// Rotary pan control: centre (0) points straight up, sweeping ±135° to hard
/// left/right. Drag vertically to turn; double-click re-centres.
private struct PanKnob: View {
    let color: Color
    @Binding var pan: Double
    @State private var dragStart: Double?

    private let sweep = 135.0

    private var angle: Double { pan * sweep }

    private var readout: String {
        if abs(pan) < 0.02 { return "C" }
        let side = pan < 0 ? "L" : "R"
        return "\(side)\(Int((abs(pan) * 100).rounded()))"
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(Theme.surface)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))

                // Deflection arc from centre (12 o'clock) to the pointer.
                PanArc(pan: pan, sweep: sweep)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(3)

                // Pointer notch.
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: 9)
                    .offset(y: -6)
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: 30, height: 30)

            Text(readout)
                .font(.system(size: 7, weight: .heavy).monospacedDigit())
                .foregroundStyle(Theme.dimmed)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStart == nil { dragStart = pan }
                    let next = (dragStart ?? 0) - Double(value.translation.height) * 0.012
                    pan = min(max(next, -1), 1)
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) { pan = 0 }
        .help("Pan — drag to turn · double-click to centre")
    }
}

/// Arc traced from 12 o'clock to the current pan position.
private struct PanArc: Shape {
    let pan: Double
    let sweep: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        // SwiftUI angles measure from 3 o'clock; 12 o'clock is -90°.
        let top = Angle.degrees(-90)
        let target = Angle.degrees(-90 + pan * sweep)
        path.addArc(center: centre, radius: radius,
                    startAngle: min(top, target), endAngle: max(top, target),
                    clockwise: false)
        return path
    }
}

// MARK: - Clip cell

private struct ClipCell: View {
    @Environment(TransportEngine.self) private var engine
    let track: Track
    let scene: Int
    @State private var dropTargeted = false

    private var clip: Clip? { track.slots[scene] }
    private var slotRef: SlotRef { SlotRef(trackID: track.id, scene: scene) }
    private var state: TrackPlayback? { engine.playback[track.id] }
    private var isRecordingHere: Bool { engine.recordingSlot == slotRef }

    var body: some View {
        content
            .frame(width: GridMetrics.cellWidth, height: GridMetrics.cellHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(dropTargeted ? Theme.cyan : .clear, lineWidth: 2)
            )
            .onDrop(of: [UTType.fileURL, UTType.plainText], isTargeted: $dropTargeted) { providers in
                handleDrop(providers)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let clip {
            FilledCell(clip: clip, track: track, scene: scene,
                       isRecordingHere: isRecordingHere)
        } else {
            emptyCell
        }
    }

    private var emptyCell: some View {
        Button {
            if isRecordingHere {
                engine.finishRecordingAndPlay()
            } else if track.isArmed {
                engine.recordIntoSlot(track, scene: scene)
            } else if engine.mode == .stopped {
                engine.selectTrack(track)
                engine.statusMessage = "Arm \(track.name) (● in its header) to record into empty slots."
            } else {
                engine.stopClip(on: track)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isRecordingHere ? Theme.coral.opacity(0.85) : Theme.surface)
                if isRecordingHere {
                    RecordingIndicator(queued: engine.recordQueuedUntilBeat != nil,
                                       countingIn: engine.isCountingIn)
                } else if track.isArmed {
                    Circle()
                        .strokeBorder(Theme.coral.opacity(0.8), lineWidth: 2)
                        .frame(width: 11, height: 11)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.07))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .buttonStyle(.plain)
        .help(track.isArmed ? "Record into this slot" : "Stop this track's clip")
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            let destinationTrack = track
            let destinationScene = scene
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                }
                guard let url else { return }
                Task { @MainActor in
                    engine.importAudioFile(url, into: destinationTrack, scene: destinationScene)
                }
            }
            return true
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            let destination = slotRef
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                var payload: String?
                if let data = item as? Data {
                    payload = String(data: data, encoding: .utf8)
                } else if let text = item as? String {
                    payload = text
                } else if let text = item as? NSString {
                    payload = text as String
                }
                guard let payload else { return }
                Task { @MainActor in
                    engine.handleClipDropPayload(payload, destination: destination)
                }
            }
            return true
        }
        return false
    }
}

/// A cell containing a clip: colour fill, waveform thumbnail, name, and
/// launch state (queued pulse, playing progress ring).
private struct FilledCell: View {
    @Environment(TransportEngine.self) private var engine
    let clip: Clip
    let track: Track
    let scene: Int
    let isRecordingHere: Bool

    private var color: Color { Theme.trackPalette[clip.colorIndex % Theme.trackPalette.count] }
    private var state: TrackPlayback? { engine.playback[track.id] }
    private var isPlaying: Bool { state?.playingClipID == clip.id }
    private var isQueued: Bool { state?.queuedClipID == clip.id }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !(isPlaying || isQueued))) { _ in
            cellBody
        }
        .onDrag {
            NSItemProvider(object: "clipmove:\(track.id.uuidString):\(scene)" as NSString)
        }
        .contextMenu {
            ForEach(0..<Theme.trackPalette.count, id: \.self) { index in
                Button {
                    clip.colorIndex = index
                } label: {
                    Label(Theme.paletteNames[index],
                          systemImage: clip.colorIndex == index ? "checkmark.circle.fill" : "circle.fill")
                }
            }
            Divider()
            Button("Delete Clip", role: .destructive) {
                engine.deleteClip(on: track, scene: scene)
            }
        }
    }

    private var slotRef: SlotRef { SlotRef(trackID: track.id, scene: scene) }

    private var cellBody: some View {
        let beats = engine.currentBeats
        let queuedPulse = isQueued ? 0.35 + 0.65 * (1 - (beats - beats.rounded(.down))) : 0
        let isSelected = engine.selectedSlot == slotRef

        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(isPlaying ? 1 : 0.68))

            WaveformShape(peaks: clip.waveform)
                .fill(Color.white.opacity(0.4))
                .padding(.horizontal, 6)
                .padding(.vertical, 7)

            HStack(spacing: 6) {
                playButton
                VStack(alignment: .leading, spacing: 1) {
                    Text(clip.name)
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(1)
                    Text("\(clip.loopBars) bar\(clip.loopBars == 1 ? "" : "s")")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(0.65)
                }
                .foregroundStyle(Color.black.opacity(0.75))
                Spacer()
                if isPlaying {
                    progressRing(beats: beats)
                }
            }
            .padding(.horizontal, 6)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(queuedPulse), lineWidth: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.white.opacity(0.9) : .clear, lineWidth: 2)
        )
        .shadow(color: isPlaying ? color.opacity(0.55) : .clear, radius: 7)
        .contentShape(Rectangle())
        .onTapGesture {
            engine.selectTrack(track)
            engine.selectedSlot = slotRef
        }
        .help(isQueued ? "Queued…" : "▶ launches · click selects · DEL deletes")
    }

    /// Live-style launch button — the only part of the cell that plays.
    private var playButton: some View {
        Button {
            engine.selectedSlot = slotRef
            engine.launch(clip: clip, on: track)
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Color.black.opacity(0.8))
                .frame(width: 19, height: 19)
                .background(Circle().fill(Color.white.opacity(isPlaying ? 0.9 : 0.55)))
        }
        .buttonStyle(.plain)
        .help("Launch clip")
    }

    private func progressRing(beats: Double) -> some View {
        let loopBeats = Double(clip.loopBars * engine.beatsPerBar)
        let elapsed = beats - (state?.playingStartBeat ?? 0)
        let fraction = loopBeats > 0 ? (elapsed.truncatingRemainder(dividingBy: loopBeats)) / loopBeats : 0
        return ZStack {
            Circle()
                .stroke(Color.black.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(Color.black.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
    }
}

/// Pulsing record indicator for a slot that is armed-and-recording.
private struct RecordingIndicator: View {
    let queued: Bool
    let countingIn: Bool

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.55 + 0.45 * sin(phase * 6)
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.black.opacity(0.75))
                    .frame(width: 10, height: 10)
                    .opacity(pulse)
                Text(queued || countingIn ? "…" : "REC")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.75))
            }
        }
    }
}

