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
