import AVFoundation
import DirigibleCore

/// A linked look-ahead true-peak limiter (decision 0032): one gain for all channels, so the
/// stereo image stays. It delays the signal by `latency` frames. `process` keeps back the last
/// frames, and `drain` gives them at the end, so the output length equals the input length.
///
/// Per input frame n: the true peak t of the FIR window that ends at n, the needed gain
/// r = min(1, c / t), the minimum of r over `ramp` + 12 frames, a one-pole release, and the mean
/// of the last `ramp` values. Each frame gets a gain at or under r of each window that holds it.
/// Under the ceiling the gain is exactly 1, so the output equals the input bit for bit.
struct TruePeakLimiter: Sendable {
    /// The internal ceiling is this many dB under the asked ceiling. It covers the gain change
    /// inside the 12 taps (at most 0.0013 dB in the candidate A probes), the Float math, and the
    /// 16-bit dither.
    static let margin = 0.05
    /// The look-ahead ramp in seconds.
    static let attack = 0.005
    /// The time constant of the release in seconds.
    static let release = 0.050

    /// The frames of delay: the ramp and the FIR window.
    let latency: Int
    private let ceiling: Double
    private let ramp: Int
    private let recovery: Double
    private let channels: Int
    private var filter: TruePeakFilter
    private var detector: [Float] = []
    /// The needed gains under 1 in the last `ramp` + 12 frames, in a ring. Each value is smaller
    /// than the one before it, so the first value is the minimum.
    private var queue: [(frame: Int, gain: Double)]
    private var head = 0
    private var queued = 0
    private var held = 1.0
    /// The last `ramp` held gains, their sum, and the count of values under 1.
    private var box: [Double]
    private var boxIndex = 0
    private var boxSum: Double
    private var boxUnder = 0
    /// The last `latency` input frames, frame by frame.
    private var delay: [Float]
    private var frames = 0
    private var drainFrames: Int

    init(ceiling dBTP: Double, rate: Int, layout: ChannelLayout) {
        ceiling = pow(10, (dBTP - Self.margin) / 20)
        ramp = max(1, Int((Self.attack * Double(rate)).rounded()))
        latency = ramp + TruePeakFilter.history - 1
        recovery = 1 - exp(-1 / (Self.release * Double(rate)))
        channels = layout.channelCount
        filter = TruePeakFilter(channels: channels)
        queue = Array(repeating: (0, 1), count: ramp + TruePeakFilter.taps)
        box = Array(repeating: 1, count: ramp)
        boxSum = Double(ramp)
        delay = Array(repeating: 0, count: latency * channels)
        drainFrames = latency
    }

    /// Limits `buffer` in place. The first `latency` frames of the signal stay inside, so the
    /// frame count of the first buffers goes down.
    /// Precondition: deinterleaved Float32 with the channel count of the layout.
    mutating func process(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        guard count > 0, let data = buffer.floatChannelData else { return }
        filter.peaks(buffer, into: &detector)
        let window = ramp + TruePeakFilter.history
        var written = 0
        for index in 0..<count {
            let peak = Double(detector[index])
            if peak.isFinite, peak > ceiling {
                let needed = ceiling / peak
                while queued > 0, queue[(head + queued - 1) % queue.count].gain >= needed { queued -= 1 }
                queue[(head + queued) % queue.count] = (frames, needed)
                queued += 1
            }
            if queued > 0, queue[head].frame <= frames - window {
                head = (head + 1) % queue.count
                queued -= 1
            }
            var recovered = held + (1 - held) * recovery
            if recovered > 1 - 1e-9 { recovered = 1 }
            held = min(queued > 0 ? queue[head].gain : 1, recovered)
            let leaving = box[boxIndex]
            box[boxIndex] = held
            boxIndex = (boxIndex + 1) % ramp
            boxUnder += (held < 1 ? 1 : 0) - (leaving < 1 ? 1 : 0)
            boxSum = boxUnder == 0 ? Double(ramp) : boxSum + held - leaving
            let gain = Float(boxUnder == 0 ? 1 : boxSum / Double(ramp))
            let slot = (frames % latency) * channels
            for channel in 0..<channels {
                let late = delay[slot + channel]
                delay[slot + channel] = data[channel][index]
                if frames >= latency { data[channel][written] = late * gain }
            }
            if frames >= latency { written += 1 }
            frames += 1
        }
        buffer.frameLength = AVAudioFrameCount(written)
    }

    /// Sends up to the capacity of `buffer` of the `latency` zero frames that end the signal
    /// through `process`, so `buffer` gets the last frames. False when all were sent.
    mutating func drain(into buffer: AVAudioPCMBuffer) -> Bool {
        guard drainFrames > 0, let data = buffer.floatChannelData else { return false }
        let count = min(Int(buffer.frameCapacity), drainFrames)
        for channel in 0..<channels { data[channel].update(repeating: 0, count: count) }
        buffer.frameLength = AVAudioFrameCount(count)
        drainFrames -= count
        process(buffer)
        return true
    }
}
