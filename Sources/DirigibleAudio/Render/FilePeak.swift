import AVFoundation

/// The sample peak of the samples that `ExtAudioFile` writes to a PCM file at `fileRate` from
/// buffers in the `client` format. At another rate it runs the buffers through an
/// `AVAudioConverter` with its default settings (medium quality, the normal algorithm, the normal
/// prime). These are the settings of the converter of `ExtAudioFile`, and the two give the same
/// samples (probe gate1-src of run `2026-10-28-stem-export`: a difference of 0).
struct FilePeak {
    private(set) var value: Float = 0
    private let converter: AVAudioConverter?
    private let output: AVAudioPCMBuffer?

    init(client: AVAudioFormat, fileRate: Int) throws(ExportError) {
        guard Int(client.sampleRate) != fileRate else {
            (converter, output) = (nil, nil)
            return
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(fileRate), channels: client.channelCount),
            let converter = AVAudioConverter(from: client, to: format),
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192)
        else { throw .writeFailed(kAudio_ParamError) }
        (self.converter, self.output) = (converter, output)
    }

    /// Adds the frames of `buffer` in the client format.
    mutating func feed(_ buffer: AVAudioPCMBuffer) throws(ExportError) {
        guard converter != nil else {
            value = max(value, peak(of: buffer))
            return
        }
        try convert(buffer, then: .noDataNow)
    }

    /// Adds the frames that the converter still holds, after the last buffer.
    mutating func finish() throws(ExportError) {
        if converter != nil { try convert(nil, then: .endOfStream) }
    }

    /// Converts `buffer`, then gives `after` to the converter, and measures each output.
    private mutating func convert(
        _ buffer: AVAudioPCMBuffer?, then after: AVAudioConverterInputStatus
    ) throws(ExportError) {
        guard let converter, let output else { return }
        // The converter calls the block on this thread, inside `convert`.
        nonisolated(unsafe) var pending = buffer
        while true {
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { _, status in
                defer { pending = nil }
                status.pointee = pending == nil ? after : .haveData
                return pending
            }
            if result == .error { throw .writeFailed(status(of: error)) }
            if output.frameLength > 0 { value = max(value, peak(of: output)) }
            if result != .haveData { return }
        }
    }
}
