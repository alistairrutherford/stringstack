import AVFoundation

enum AudioUtil {
    /// Converts a buffer to the given format (sample rate / channel count),
    /// returning the original if it already matches.
    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return conversionError == nil ? output : nil
    }

    /// Sums `overlay` onto a copy of `base` (for overdub), clamped to
    /// [-1, 1]. Result length matches `base`; `overlay` is added where the
    /// two overlap. Both are assumed to share `base`'s format.
    static func mix(base: AVAudioPCMBuffer, overlay: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let baseData = base.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: base.format, frameCapacity: base.frameLength),
              let outData = out.floatChannelData else { return nil }
        out.frameLength = base.frameLength
        let channels = Int(base.format.channelCount)
        let baseFrames = Int(base.frameLength)
        for channel in 0..<channels {
            outData[channel].update(from: baseData[channel], count: baseFrames)
        }
        if let overlayData = overlay.floatChannelData {
            let overlayFrames = min(baseFrames, Int(overlay.frameLength))
            let overlayChannels = Int(overlay.format.channelCount)
            for channel in 0..<channels {
                let source = overlayData[min(channel, overlayChannels - 1)]
                for frame in 0..<overlayFrames {
                    var sample = outData[channel][frame] + source[frame]
                    sample = max(-1, min(1, sample))
                    outData[channel][frame] = sample
                }
            }
        }
        return out
    }

    /// Copies `frames` frames starting at `start` into a new buffer.
    static func slice(_ buffer: AVAudioPCMBuffer, from start: Int, frames: Int) -> AVAudioPCMBuffer? {
        guard frames > 0, start >= 0, start + frames <= Int(buffer.frameLength),
              let source = buffer.floatChannelData,
              let output = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData else { return nil }
        output.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel] + start, count: frames)
        }
        return output
    }
}
