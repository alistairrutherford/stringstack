import AVFoundation
import Accelerate
import Synchronization

/// Captures audio from the engine's input node via a tap, tracks input level,
/// and assembles the take into a bar-aligned loop buffer.
///
/// Alignment: every tap buffer arrives with a host timestamp. Chunks are laid
/// into the output relative to the transport's beat-zero host time, so audio
/// captured during the count-in is trimmed and the loop starts exactly on
/// bar 1 regardless of tap start latency.
final class RecordingService: @unchecked Sendable {

    private let lock = NSLock()
    private var chunks: [(buffer: AVAudioPCMBuffer, hostTime: UInt64)] = []
    private let peakBits = Atomic<UInt64>(0.0.bitPattern)
    private let capturingFlag = Atomic<Bool>(false)
    /// Input gain applied to captured audio and reflected in the meter.
    private let gainBits = Atomic<UInt64>(1.0.bitPattern)

    func setInputGain(_ gain: Double) {
        gainBits.store(max(0, gain).bitPattern, ordering: .relaxed)
    }

    private(set) var captureFormat: AVAudioFormat?
    /// Main-thread bookkeeping so the tap is installed exactly once per
    /// configured input; the level meter runs whenever the tap is present,
    /// capture is gated by `capturingFlag`.
    private(set) var isTapInstalled = false

    /// Smoothed input peak (0...1), fed by the tap; polled by the level meter.
    var inputPeak: Double { Double(bitPattern: peakBits.load(ordering: .relaxed)) }

    // MARK: - Tap lifecycle

    /// Installs the persistent monitoring/capture tap. Call with the engine
    /// stopped and prepared, after the input device has been applied.
    /// The tap uses the bus's own format (nil) so it can't pin a stale
    /// format from before a device change; `captureFormat` is refreshed from
    /// the actual buffers as they arrive.
    func installTap(on inputNode: AVAudioInputNode) {
        if isTapInstalled { inputNode.removeTap(onBus: 0) }
        captureFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, when in
            guard let self else { return }
            let gain = Float(Double(bitPattern: self.gainBits.load(ordering: .relaxed)))
            self.captureFormat = buffer.format
            self.updatePeak(from: buffer, gain: gain)
            guard self.capturingFlag.load(ordering: .relaxed),
                  let copy = Self.copyBuffer(buffer, gain: gain) else { return }
            self.lock.lock()
            self.chunks.append((copy, when.hostTime))
            self.lock.unlock()
        }
        isTapInstalled = true
    }

    func removeTap(from inputNode: AVAudioInputNode) {
        guard isTapInstalled else { return }
        inputNode.removeTap(onBus: 0)
        isTapInstalled = false
        capturingFlag.store(false, ordering: .relaxed)
        peakBits.store(0.0.bitPattern, ordering: .relaxed)
    }

    // MARK: - Capture

    func beginCapture() {
        lock.lock()
        chunks.removeAll()
        lock.unlock()
        capturingFlag.store(true, ordering: .relaxed)
    }

    func endCapture() {
        capturingFlag.store(false, ordering: .relaxed)
    }

    func discard() {
        endCapture()
        lock.lock()
        chunks.removeAll()
        lock.unlock()
    }

    // MARK: - Loop assembly

    /// Builds a loop of exactly `frameCount` frames starting at `beat0Host`,
    /// dropping count-in audio and padding any shortfall with silence.
    func makeLoopBuffer(beat0Host: UInt64, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        endCapture()
        lock.lock()
        let captured = chunks
        chunks = []
        lock.unlock()

        guard let format = captured.first?.buffer.format,
              frameCount > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let dst = out.floatChannelData else { return nil }

        out.frameLength = frameCount
        let channelCount = Int(format.channelCount)
        let totalFrames = Int(frameCount)
        for channel in 0..<channelCount {
            dst[channel].update(repeating: 0, count: totalFrames)
        }

        for (buffer, hostTime) in captured {
            guard let src = buffer.floatChannelData else { continue }
            let offsetSeconds = (Double(hostTime) - Double(beat0Host)) * HostClock.secondsPerTick
            let chunkStart = Int((offsetSeconds * format.sampleRate).rounded())
            let chunkFrames = Int(buffer.frameLength)
            let srcStart = max(0, -chunkStart)
            let dstStart = max(0, chunkStart)
            let count = min(chunkFrames - srcStart, totalFrames - dstStart)
            guard count > 0 else { continue }
            for channel in 0..<channelCount {
                (dst[channel] + dstStart).update(from: src[channel] + srcStart, count: count)
            }
        }
        return out
    }

    /// Persists a clip buffer as a CAF in Application Support/Recordings.
    func writeFile(buffer: AVAudioPCMBuffer, name: String) -> URL? {
        do {
            let directory = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask,
                     appropriateFor: nil, create: true)
                .appendingPathComponent("Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).caf")
            let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            try file.write(from: buffer)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func updatePeak(from buffer: AVAudioPCMBuffer, gain: Float) {
        guard let data = buffer.floatChannelData else { return }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var channelPeak: Float = 0
            vDSP_maxmgv(data[channel], 1, &channelPeak, vDSP_Length(buffer.frameLength))
            peak = max(peak, channelPeak)
        }
        let smoothed = max(Double(peak * gain), inputPeak * 0.82)
        peakBits.store(smoothed.bitPattern, ordering: .relaxed)
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer, gain: Float) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData,
              let dst = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        let count = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            if gain == 1 {
                dst[channel].update(from: src[channel], count: count)
            } else {
                var scale = gain
                vDSP_vsmul(src[channel], 1, &scale, dst[channel], 1, vDSP_Length(count))
            }
        }
        return copy
    }
}
