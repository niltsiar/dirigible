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
    /// Gets a non-decreasing fraction in 0...1, and 1 only at the end, after the read-back. A
    /// same-rate copy of integer PCM never exceeds full scale, so its one pass gives 0..<1. Else
    /// pass 1 gives 0...0.5 and pass 2 0.5..<1: a float input or a resample can exceed full scale
    /// (A11).
    var progress: (Double) -> Void = { _ in }
    /// Read before each block and before the read-back. When it is true, `convert` returns nil.
    var isCancelled: () -> Bool = { false }
    /// With a stereo input into 1 channel, the WAV takes only this side, not 0.5 L + 0.5 R
    /// (decision 0053).
    var pick: Side? = nil
    /// The input frames to convert. Nil converts the whole input from its position.
    var span: Range<AVAudioFramePosition>? = nil

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
        if let span { input.framePosition = span.lowerBound }
        let format = input.fileFormat.streamDescription.pointee
        let integer = format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat == 0
        let share = source == rate && integer ? 1.0 : 0.5
        // The last block of a pass comes before the flush and the read-back, so a pass never gives 1.
        let report = { (fraction: Double) in if fraction < 1 { progress(fraction) } }
        guard
            var result = try pass(
                input, file: descriptor, from: source, to: rate, into: url, scale: 1,
                progress: { report($0 * share) })
        else { return nil }
        var gain = Gain.zero
        if let rescale = rescale(peak: result.peak) {
            input.framePosition = span?.lowerBound ?? 0
            guard
                let second = try pass(
                    input, file: descriptor, from: source, to: rate, into: url, scale: rescale.scale,
                    progress: { report(0.5 + $0 / 2) })
            else { return nil }
            result = second
            gain = rescale.gain
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

    /// The peak of all channels of `input` from its position, after the channel map and the
    /// converter of `convert`, with no WAV written. Nil as `convert`.
    func peak(_ input: AVAudioFile, file descriptor: Int32, from source: Double, to rate: Double)
        throws(FinalizeError) -> Float?
    {
        try pass(input, file: descriptor, from: source, to: rate, into: nil, scale: 1, progress: { _ in })?.peak
    }

    /// One read of `input` from its position into a new WAV at `url`, or into no file when `url` is
    /// nil. Each buffer that goes to the writer is multiplied by `scale` first. Returns the frame
    /// count and the peak of all channels before the scale, or nil as `convert`. `progress` gets
    /// the read fraction of the input.
    private func pass(
        _ input: AVAudioFile, file descriptor: Int32, from source: Double, to rate: Double, into url: URL?,
        scale: Float, progress: @escaping (Double) -> Void
    ) throws(FinalizeError) -> (length: Int, peak: Float)? {
        let capacity = AVAudioFrameCount(blockFrames)
        guard let output = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels),
            let read = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: capacity),
            let written = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)
        else { return nil }
        var writer: ClipWriter?
        if let url {
            try createClipsFolder(in: package)
            writer = try ClipWriter(url: url, file: wav, format: output)
        }
        let reader = BlockReader(
            input: input, descriptor: descriptor, buffer: read, span: span ?? input.framePosition..<input.length,
            fault: readFault, progress: progress, isCancelled: isCancelled)
        reader.pick = pick.map { $0 == .left ? 0 : 1 }
        var length = 0
        var peak: Float = 0
        // The peak and the scale act on the buffer that goes to the writer.
        func write(_ buffer: AVAudioPCMBuffer) throws(FinalizeError) {
            peak = max(peak, scaleInPlace(buffer, by: scale))
            try writer?.write(buffer)
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
        try writer?.close()
        return (length, peak)
    }
}

/// The scale of the second pass of `convert` and the clip gain that gives the level back, for a
/// float peak over full scale (A11). Nil for a peak of 1.0 or less, or an infinite peak: it gives
/// no finite gain, so it keeps the one pass. A finite peak always gets the second pass at the full
/// scale, because a capped scale saturates the file. Its clip gain stops at +96 dB, so a clip with
/// a peak over +96 dB plays (peak dB - 96) dB quieter than its source.
func rescale(peak: Float) -> (scale: Float, gain: Gain)? {
    let scale = Float(ceiling / Double(peak))
    guard peak > 1, let gain = Gain(clamping: -20 * log10(Double(scale))) else { return nil }
    return (scale, gain)
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

/// Reads the frames `span` of a file in blocks into one buffer. A read error that `ioErrno` gives
/// an errno sets `failure`; any other read error, or a read of no frames before the end, sets
/// `unreadable`. A cancel before a read sets `cancelled`.
/// `@unchecked Sendable`: the converter input block is `@Sendable`, but the converter calls it
/// synchronously inside `convert`, so one thread at a time uses the reader.
private final class BlockReader: @unchecked Sendable {
    let input: AVAudioFile
    let descriptor: Int32
    let buffer: AVAudioPCMBuffer
    let span: Range<AVAudioFramePosition>
    let fault: ReadFault?
    let progress: (Double) -> Void
    let isCancelled: () -> Bool
    /// A buffer at the source rate with the output channels that gets a copy of each block.
    var relabeled: AVAudioPCMBuffer?
    /// The input channel that a 2 into 1 copy takes, or nil for 0.5 L + 0.5 R.
    var pick: Int?
    private var block = 0
    private(set) var failure: Int32?
    private(set) var unreadable = false
    private(set) var cancelled = false

    init(
        input: AVAudioFile, descriptor: Int32, buffer: AVAudioPCMBuffer, span: Range<AVAudioFramePosition>,
        fault: ReadFault?, progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool
    ) {
        self.input = input
        self.descriptor = descriptor
        self.buffer = buffer
        self.span = span
        self.fault = fault
        self.progress = progress
        self.isCancelled = isCancelled
    }

    /// False at the end of the span, after an error, or after a cancel.
    func next() -> Bool {
        let position = input.framePosition
        guard failure == nil, !unreadable, !cancelled, position < span.upperBound else { return false }
        if isCancelled() {
            cancelled = true
            return false
        }
        defer { block += 1 }
        do {
            if let fault, fault.block == block { try fault.before() }
            try input.read(
                into: buffer, frameCount: min(buffer.frameCapacity, AVAudioFrameCount(span.upperBound - position)))
        } catch {
            if let code = ioErrno(of: error, file: descriptor) { failure = code } else { unreadable = true }
            return false
        }
        // A read of no frames before the end would give a short clip.
        if buffer.frameLength == 0 { unreadable = true }
        let count = span.upperBound - span.lowerBound
        progress(min(1, Double(input.framePosition - span.lowerBound) / Double(count)))
        return !unreadable
    }

    /// The next block, copied into `relabeled` with its channels: 2 into 1 is `pick` or 0.5 L + 0.5 R,
    /// and 1 into 2 goes to both. Nil at the end of the span, after an error, or after a cancel.
    func nextRelabeled() -> AVAudioPCMBuffer? {
        guard let relabeled, next(), let source = buffer.floatChannelData, let target = relabeled.floatChannelData
        else { return nil }
        let (frames, inputs, outputs) = (
            Int(buffer.frameLength), Int(buffer.format.channelCount), Int(relabeled.format.channelCount)
        )
        relabeled.frameLength = buffer.frameLength
        if inputs == 2, outputs == 1, let pick {
            target[0].update(from: source[pick], count: frames)
        } else if inputs == 2, outputs == 1 {
            var half: Float = 0.5
            vDSP_vasm(source[0], 1, source[1], 1, &half, target[0], 1, vDSP_Length(frames))
        } else {
            for channel in 0..<outputs { target[channel].update(from: source[min(channel, inputs - 1)], count: frames) }
        }
        return relabeled
    }
}
