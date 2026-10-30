import AVFoundation
import Accelerate
import DirigibleCore
import Foundation

/// The highest whole Hz of a rumble or de-ess corner that a session at `rate` takes: under 0.45 x
/// the rate (decision 0064 C19). Whole numbers only: 0.45 x 100 is not 45 in Double.
package func cornerLimit(rate: Int) -> Int { (9 * rate - 1) / 20 }

/// The lowest whole session rate that takes the corner `hertz`: the inverse of `cornerLimit`.
package func lowestRate(takingCorner hertz: Int) -> Int { 20 * hertz / 9 + 1 }

extension AVAudioPCMBuffer {
    /// The samples of each channel, from the frame `start` to the end of the buffer.
    func samples(from start: Int = 0) -> [[Float]] {
        (0..<Int(format.channelCount)).map {
            Array(UnsafeBufferPointer(start: floatChannelData![$0] + start, count: Int(frameLength) - start))
        }
    }
}

/// What step 2 of `RepairSetup` measured for a de-clip: the values that a caller keeps while the
/// span and the treatment that it measured stay the same. It holds no stage.
struct RepairMeasure: Hashable, Sendable {
    let peaks: [Float]
    let carriedBits: Int
    let scale: Float
    let runs: Int
}

/// The repair stages of one run and the guards of the clip render and the preview (decision 0064
/// D9): the one owner, so that each caller applies each guard. Step 1 is `check`, which reads no
/// audio. Step 2 is `repairSetup`, which reads the span only for a de-clip.
struct RepairSetup {
    /// The setup of a treatment with no repair kind: no stage and no scale.
    static var none: RepairSetup { RepairSetup(peaks: [], carriedBits: 24, pre: [], post: [], scale: 1, runs: 0) }

    /// The peak of each channel of the span, for the de-clip level; empty with no de-clip.
    let peaks: [Float]
    /// The bit depth that the span samples carry (decision 0064 D4).
    let carriedBits: Int
    /// The stages before the player node, in chain order: the de-clip, then the high-pass.
    let pre: [any RenderStage]
    /// The stages after the engine output, each with latency 0: the de-ess. The render adds its
    /// test seam `addedStage` here.
    var post: [any RenderStage]
    /// s1: the pass 1 scale that puts the filled peak at the import ceiling; 1 with no de-clip.
    let scale: Float
    /// The clipped runs that the de-clip fills in the span.
    let runs: Int

    /// Step 1: refuses a rumble or de-ess corner at or over 0.45 x `rate` with `.cornerTooHigh`,
    /// before any read, with no clamp. The bound is the highest whole Hz under 0.45 x `rate`, or,
    /// when that is under the range of the type, the lowest whole rate that takes the lowest value.
    static func check(_ treatment: Treatment, rate: Int) throws(ClipRenderError) {
        let corners = [
            treatment.rumble.map { ($0.hertz, Rumble.range.lowerBound) },
            treatment.deess.map { ($0.hertz, DeEss.hertzRange.lowerBound) },
        ]
        let limit = cornerLimit(rate: rate)
        for case (let hertz, let lowest)? in corners where hertz > limit {
            let bound: ClipRenderError.CornerLimit =
                limit >= lowest ? .hertz(limit) : .lowestRate(lowestRate(takingCorner: lowest))
            throw .cornerTooHigh(hertz: hertz, limit: bound)
        }
    }

    /// Refuses `buffer` when a sample of it is a NaN or an infinity, with `.nonFiniteSample`: the
    /// sum of the magnitudes of a block of samples under 2 is finite only when each sample is.
    static func checkFinite(_ buffer: AVAudioPCMBuffer, file: String) throws(ClipRenderError) {
        for channel in 0..<Int(buffer.format.channelCount) {
            var sum: Float = 0
            vDSP_svemg(buffer.floatChannelData![channel], 1, &sum, vDSP_Length(buffer.frameLength))
            guard sum.isFinite else { throw .nonFiniteSample(file: file) }
        }
    }

    var measure: RepairMeasure { RepairMeasure(peaks: peaks, carriedBits: carriedBits, scale: scale, runs: runs) }

    /// The setup of `treatment` with the values of `measure`, and new stages: for a caller that keeps
    /// a measure and runs the stages again. Step 1 runs first.
    static func measured(_ measure: RepairMeasure, _ treatment: Treatment, rate: Double, channels: Int)
        throws(ClipRenderError) -> RepairSetup
    {
        let rest = try unmeasured(treatment, rate: rate, channels: channels)
        guard let declip = treatment.declip else { return rest }
        let first = DeclipStage(
            percent: declip.percent, peaks: measure.peaks, carriedBits: measure.carriedBits, rate: rate)
        return RepairSetup(
            peaks: measure.peaks, carriedBits: measure.carriedBits, pre: [first] + rest.pre, post: rest.post,
            scale: measure.scale, runs: measure.runs)
    }

    /// Step 1, then the high-pass and the de-ess of `treatment` with no read, and no de-clip.
    static func unmeasured(_ treatment: Treatment, rate: Double, channels: Int) throws(ClipRenderError) -> RepairSetup {
        try check(treatment, rate: Int(rate))
        return RepairSetup(
            peaks: [], carriedBits: 24,
            pre: treatment.rumble.map { [RumbleStage(hertz: $0.hertz, rate: rate, channels: channels)] } ?? [],
            post: treatment.deess.map {
                [DeEssStage(hertz: $0.hertz, decibels: $0.decibels, rate: rate, channels: channels)]
            } ?? [], scale: 1, runs: 0)
    }
}

/// Step 2 of `RepairSetup` for the frames `span` of `source` (open at `descriptor` too): step 1;
/// then, with a de-clip, one read of the span for the peak of each channel and the carried bit
/// depth, and a second read through the de-clip and the high-pass for the filled peak, its scale
/// s1 (`fullScaleRepair`), and the run count. Each read holds one block of the chain. `isCancelled`
/// is read before each block; `readFault` runs before block `block` of a read when `stem` is its
/// stem (tests only). With no de-clip it reads nothing. A NaN or an infinity in the span gives
/// `.nonFiniteSample` after the first read. `file` names the source in errors.
func repairSetup(
    span: Range<AVAudioFramePosition>, of source: AVAudioFile, descriptor: Int32, treatment: Treatment,
    file: String, stem: String, readFault: ReadFault?, isCancelled: () -> Bool
) throws(ClipRenderError) -> RepairSetup {
    let (rate, channels) = (source.processingFormat.sampleRate, Int(source.processingFormat.channelCount))
    let unmeasured = try RepairSetup.unmeasured(treatment, rate: rate, channels: channels)
    guard let declip = treatment.declip else { return unmeasured }
    func blocks(_ body: ([[Float]], Bool) -> Void) throws(ClipRenderError) {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(EffectChain.blockFrames))
        else { throw .engine(status: kAudio_MemFullError) }
        source.framePosition = span.lowerBound
        var (left, block) = (Int(span.upperBound - span.lowerBound), 0)
        while left > 0 {
            guard !isCancelled() else { throw .cancelled }
            do {
                if let readFault, readFault.stem == stem, readFault.block == block { try readFault.before() }
                try source.read(into: buffer, frameCount: AVAudioFrameCount(min(EffectChain.blockFrames, left)))
            } catch {
                throw .sourceUnreadable(file: file, errno: ioErrno(of: error, file: descriptor) ?? EIO)
            }
            guard buffer.frameLength > 0 else { throw .sourceUnreadable(file: file, errno: EIO) }
            left -= Int(buffer.frameLength)
            block += 1
            body(buffer.samples(), left == 0)
        }
    }
    var peaks = [Float](repeating: 0, count: channels)
    var (codes, offGrid, finite) = (Int64(0), false, true)
    try blocks { block, _ in
        for (channel, samples) in block.enumerated() {
            peaks[channel] = max(peaks[channel], vDSP.maximumMagnitude(samples))
            for sample in samples {
                finite = finite && sample.isFinite
                // A code of 2^63 or more (a sample of 2^40 or more) is off the grid of each depth.
                let code = Double(sample) * 0x1p23
                if code.rounded() == code, let whole = Int64(exactly: abs(code)) {
                    codes |= whole
                } else {
                    offGrid = true
                }
            }
        }
    }
    guard finite else { throw .nonFiniteSample(file: file) }
    // The smallest depth b whose grid 1 / 2^(b - 1) holds each sample, or 24 off the 24-bit grid.
    let carriedBits = offGrid || codes == 0 ? 24 : max(1, 24 - codes.trailingZeroBitCount)
    let first = DeclipStage(percent: declip.percent, peaks: peaks, carriedBits: carriedBits, rate: rate)
    var stages: [any RenderStage] = [first] + unmeasured.pre
    var filled: Float = 0
    try blocks { block, last in
        for samples in stages.process(block, last: last) { filled = max(filled, vDSP.maximumMagnitude(samples)) }
    }
    let measure = RepairMeasure(
        peaks: peaks, carriedBits: carriedBits, scale: fullScaleRepair(filled) ?? 1,
        runs: (stages.first as? DeclipStage)?.runs ?? 0)
    return try RepairSetup.measured(measure, treatment, rate: rate, channels: channels)
}
