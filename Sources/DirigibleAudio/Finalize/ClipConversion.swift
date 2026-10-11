import AVFoundation
import Accelerate
import DirigibleCore
import Foundation

/// The conversion of one audio file into a 24-bit WAV at the session rate (decisions 0012 and
/// 0040). Finalize and import share it.
struct ClipConversion {
    let package: URL
    /// The package-relative path of the WAV, for errors.
    let wav: String
    let blockFrames: Int
    /// The read fault of this input. Only tests give one.
    let readFault: ReadFault?
    /// The error of a read errno of the input.
    let unreadable: (Int32) -> FinalizeError
    /// The channel count of the WAV. A stereo input into 1 channel is 0.5 L + 0.5 R; a mono input
    /// into 2 channels goes to both.
    let channels: AVAudioChannelCount
    /// Gets a non-decreasing fraction in 0...1: pass 1 gives 0...0.5, pass 2 0.5...1, and the end 1.
    var progress: (Double) -> Void = { _ in }
    /// Read before each block and before the read-back. When it is true, `convert` returns nil.
    var isCancelled: () -> Bool = { false }

    /// Reads `input` (open at `descriptor` too) in blocks, maps its channels to `channels`,
    /// converts it from `source` to `rate` through one converter when the rates differ, and
    /// writes, flushes, and reads back the WAV at `url`, the temporary name. Returns the frame
    /// count of the WAV and the clip gain, or nil for a bad input, a converter that stops before
    /// the end of the stream, a WAV length that does not read back, or a cancel.
    ///
    /// A float peak over full scale saturates in 24 bits (A11). Then a second pass scales the whole
    /// input to `ceiling`, and the clip gain gives the level back. A peak of 1.0 or less reads the
    /// input once and keeps gain 0 dB.
    func convert(
        _ input: AVAudioFile, file descriptor: Int32, from source: Double, to rate: Double, into url: URL
    ) throws(FinalizeError) -> (length: Int, gain: Gain)? {
        guard
            var result = try pass(
                input, file: descriptor, from: source, to: rate, into: url, scale: 1, progress: { progress($0 / 2) })
        else { return nil }
        var gain = Gain.zero
        // An infinite peak gives no finite gain, so it keeps the one pass. A finite peak always gets
        // the second pass at the full scale, because a capped scale saturates the file. Its clip
        // gain stops at +96 dB, so a clip with a peak over +96 dB plays (peak dB - 96) dB quieter
        // than its source.
        let scale = Float(ceiling / Double(result.peak))
        if result.peak > 1, let scaled = Gain(clamping: -20 * log10(Double(scale))) {
            input.framePosition = 0
            guard
                let second = try pass(
                    input, file: descriptor, from: source, to: rate, into: url, scale: scale,
                    progress: { progress(0.5 + $0 / 2) })
            else { return nil }
            result = second
            gain = scaled
        }
        guard !isCancelled() else { return nil }
        let clip = open(url.path, O_RDONLY | O_CLOEXEC)
        guard clip >= 0 else { throw .readFailed(file: wav, errno: errno) }
        defer { close(clip) }
        if let code = fullFlush(clip) { throw .writeFailed(file: wav, status: code) }
        do {
            guard try AVAudioFile(forReading: url).length == AVAudioFramePosition(result.length) else { return nil }
        } catch {
            if let code = ioErrno(of: error, file: clip) { throw .readFailed(file: wav, errno: code) }
            return nil
        }
        progress(1)
        return (result.length, gain)
    }

    /// One read of `input` from its position into a new WAV at `url`. Each buffer that goes to the
    /// writer is multiplied by `scale` first. Returns the frame count and the peak of all channels
    /// before the scale, or nil as `convert`. `progress` gets the read fraction of the input.
    private func pass(
        _ input: AVAudioFile, file descriptor: Int32, from source: Double, to rate: Double, into url: URL,
        scale: Float, progress: @escaping (Double) -> Void
    ) throws(FinalizeError) -> (length: Int, peak: Float)? {
        let capacity = AVAudioFrameCount(blockFrames)
        guard let output = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels),
            let read = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: capacity),
            let written = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)
        else { return nil }
        try createClipsFolder(in: package)
        let writer = try ClipWriter(url: url, file: wav, format: output)
        let reader = BlockReader(
            input: input, descriptor: descriptor, buffer: read, fault: readFault, progress: progress,
            isCancelled: isCancelled)
        var length = 0
        var peak: Float = 0
        // The peak and the scale act on the buffer that goes to the writer.
        func write(_ buffer: AVAudioPCMBuffer) throws(FinalizeError) {
            peak = max(peak, scaleInPlace(buffer, by: scale))
            try writer.write(buffer)
            length += Int(buffer.frameLength)
        }
        // The same-rate path has no converter and ends at the end of the stream. Its copy of each
        // block keeps each sample.
        var status = AVAudioConverterOutputStatus.endOfStream

        if source == rate {
            reader.relabeled = written
            while let block = reader.nextRelabeled() { try write(block) }
        } else {
            guard let from = AVAudioFormat(standardFormatWithSampleRate: source, channels: channels),
                let converter = AVAudioConverter(from: from, to: output),
                let fed = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: capacity)
            else { return nil }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
            reader.relabeled = fed
            status = .haveData
            while status == .haveData {
                var error: NSError?
                status = converter.convert(to: written, error: &error) { _, inputStatus in
                    let block = reader.nextRelabeled()
                    inputStatus.pointee = block == nil ? .endOfStream : .haveData
                    return block
                }
                if reader.failure != nil || reader.cancelled || status == .error { break }
                try write(written)
            }
        }
        if let failure = reader.failure { throw unreadable(failure) }
        // A converter that ends in .error or .inputRanDry gives a short clip; a placed clip holds
        // the whole input.
        guard !reader.unreadable, !reader.cancelled, status == .endOfStream else { return nil }
        try writer.close()
        return (length, peak)
    }
}

/// The level of the peak sample after the scale of a second pass: two 24-bit steps under full
/// scale, so the peak gets code 8388606 and no sample saturates (A11).
private let ceiling = 1 - 0x1p-22

/// Multiplies each channel of `buffer` by `scale` when it is not 1, and returns the peak of all
/// channels before the scale.
private func scaleInPlace(_ buffer: AVAudioPCMBuffer, by scale: Float) -> Float {
    guard let data = buffer.floatChannelData else { return 0 }
    let frames = vDSP_Length(buffer.frameLength)
    var peak: Float = 0
    for channel in 0..<Int(buffer.format.channelCount) {
        var level: Float = 0
        vDSP_maxmgv(data[channel], 1, &level, frames)
        peak = max(peak, level)
        if scale != 1 {
            var factor = scale
            vDSP_vsmul(data[channel], 1, &factor, data[channel], 1, frames)
        }
    }
    return peak
}

/// Reads a file in blocks into one buffer. A read error that `ioErrno` gives an errno sets
/// `failure`; any other read error, or a read of no frames before the end, sets `unreadable`. A
/// cancel before a read sets `cancelled`.
/// `@unchecked Sendable`: the converter input block is `@Sendable`, but the converter calls it
/// synchronously inside `convert`, so one thread at a time uses the reader.
private final class BlockReader: @unchecked Sendable {
    let input: AVAudioFile
    let descriptor: Int32
    let buffer: AVAudioPCMBuffer
    let fault: ReadFault?
    let progress: (Double) -> Void
    let isCancelled: () -> Bool
    /// A buffer at the source rate with the output channels that gets a copy of each block.
    var relabeled: AVAudioPCMBuffer?
    private var block = 0
    private(set) var failure: Int32?
    private(set) var unreadable = false
    private(set) var cancelled = false

    init(
        input: AVAudioFile, descriptor: Int32, buffer: AVAudioPCMBuffer, fault: ReadFault?,
        progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool
    ) {
        self.input = input
        self.descriptor = descriptor
        self.buffer = buffer
        self.fault = fault
        self.progress = progress
        self.isCancelled = isCancelled
    }

    /// False at the end of the file, after an error, or after a cancel.
    func next() -> Bool {
        guard failure == nil, !unreadable, !cancelled, input.framePosition < input.length else { return false }
        if isCancelled() {
            cancelled = true
            return false
        }
        defer { block += 1 }
        do {
            if let fault, fault.block == block { try fault.before() }
            try input.read(into: buffer, frameCount: buffer.frameCapacity)
        } catch {
            if let code = ioErrno(of: error, file: descriptor) { failure = code } else { unreadable = true }
            return false
        }
        // A read of no frames before the end would give a short clip.
        if buffer.frameLength == 0 { unreadable = true }
        progress(min(1, Double(input.framePosition) / Double(input.length)))
        return !unreadable
    }

    /// The next block, copied into `relabeled` with its channels: 2 into 1 is 0.5 L + 0.5 R, and 1
    /// into 2 goes to both. Nil at the end of the file, after an error, or after a cancel.
    func nextRelabeled() -> AVAudioPCMBuffer? {
        guard let relabeled, next(), let source = buffer.floatChannelData, let target = relabeled.floatChannelData
        else { return nil }
        let (frames, inputs, outputs) = (
            Int(buffer.frameLength), Int(buffer.format.channelCount), Int(relabeled.format.channelCount)
        )
        relabeled.frameLength = buffer.frameLength
        if inputs == 2, outputs == 1 {
            var half: Float = 0.5
            vDSP_vasm(source[0], 1, source[1], 1, &half, target[0], 1, vDSP_Length(frames))
        } else {
            for channel in 0..<outputs { target[channel].update(from: source[min(channel, inputs - 1)], count: frames) }
        }
        return relabeled
    }
}
