import Foundation

/// A stage of the clip render outside the engine (decision 0064 D1). It runs only in the offline
/// render, never on a real-time thread. `process` takes one block, one array for each channel, and
/// gives as many frames, delayed by `latency` frames: the first `latency` frames of the stream are
/// zeros. `finish` gives the last `latency` frames. So n frames in give n + `latency` frames out.
protocol RenderStage {
    /// The frames that the output lags the input.
    var latency: Int { get }
    /// The frames that the stage holds for each channel: at most `latency` after each call.
    var held: Int { get }
    mutating func process(_ block: [[Float]]) -> [[Float]]
    mutating func finish() -> [[Float]]
}

extension Array where Element == any RenderStage {
    /// `block` through the stages in order. On the `last` block each stage also gives its held
    /// frames, which the stages after it process.
    mutating func process(_ block: [[Float]], last: Bool = false) -> [[Float]] {
        var data = block
        for index in indices {
            var output = self[index].process(data)
            if last { for (channel, tail) in self[index].finish().enumerated() { output[channel] += tail } }
            data = output
        }
        return data
    }
}

/// The RBJ high-pass at `hertz`, Q 0.70711 (a 2nd-order Butterworth), for one channel. It runs in
/// Double, sample by sample, with its state kept across blocks, so each split of a stream into
/// blocks gives the same output; a Float `vDSP.Biquad` does not (1.3e-4 at 80 Hz, C1). Its response
/// equals `AVAudioUnitEQ` `.highPass` to 0.01 dB.
private struct HighPass {
    private let b0: Double
    private let b1: Double
    private let a1: Double
    private let a2: Double
    private var (x1, x2, y1, y2) = (0.0, 0.0, 0.0, 0.0)

    init(hertz: Int, rate: Double) {
        let omega = 2 * Double.pi * Double(hertz) / rate
        let (alpha, cosine) = (sin(omega) / (2 * 0.70711), cos(omega))
        let a0 = 1 + alpha
        (b0, b1) = ((1 + cosine) / 2 / a0, -(1 + cosine) / a0)
        (a1, a2) = (-2 * cosine / a0, (1 - alpha) / a0)
    }

    mutating func apply(_ samples: [Float]) -> [Double] {
        var output: [Double] = []
        output.reserveCapacity(samples.count)
        for sample in samples {
            let x = Double(sample)
            let y = b0 * x + b1 * x1 + b0 * x2 - a1 * y1 - a2 * y2
            (x2, x1, y2, y1) = (x1, x, y1, y)
            output.append(y)
        }
        return output
    }
}

/// Reduce Rumble (decision 0064 D3): a 12 dB per octave high-pass at `hertz`, one filter for each
/// channel, with its state kept across blocks.
struct RumbleStage: RenderStage {
    let latency = 0
    let held = 0
    private var filters: [HighPass]

    init(hertz: Int, rate: Double, channels: Int) {
        filters = Array(repeating: HighPass(hertz: hertz, rate: rate), count: channels)
    }

    mutating func process(_ block: [[Float]]) -> [[Float]] {
        var output: [[Float]] = []
        for channel in block.indices { output.append(filters[channel].apply(block[channel]).map { Float($0) }) }
        return output
    }

    mutating func finish() -> [[Float]] { filters.map { _ in [] } }
}

/// Soften "S" Sounds (decision 0064 D5): a split-band de-esser. The high band is a 2nd-order
/// high-pass at `hertz`. Peak envelopes (attack 0.5 ms, release 60 ms) of the high band and of the
/// full band of the channel with the largest full-band envelope give the ratio; the cut is the
/// ratio in dB plus 10, clamped to 0 and `decibels`, and 0 while that full-band envelope is under
/// -100 dBFS (digital silence). The output is x - (1 - g) x high, with one g for all channels, so a
/// frame with no cut is the input.
struct DeEssStage: RenderStage {
    let latency = 0
    let held = 0
    private let decibels: Double
    private let attack: Double
    private let release: Double
    private var filters: [HighPass]
    private var full: [Double]
    private var high: [Double]

    init(hertz: Int, decibels: Int, rate: Double, channels: Int) {
        filters = Array(repeating: HighPass(hertz: hertz, rate: rate), count: channels)
        self.decibels = Double(decibels)
        attack = exp(-1 / (0.0005 * rate))
        release = exp(-1 / (0.060 * rate))
        full = Array(repeating: 0, count: channels)
        high = Array(repeating: 0, count: channels)
    }

    mutating func process(_ block: [[Float]]) -> [[Float]] {
        var bands: [[Double]] = []
        for channel in block.indices { bands.append(filters[channel].apply(block[channel])) }
        var output = block
        for frame in block[0].indices {
            var loudest = 0
            for channel in block.indices {
                full[channel] = follow(full[channel], Double(abs(block[channel][frame])))
                high[channel] = follow(high[channel], abs(bands[channel][frame]))
                if full[channel] > full[loudest] { loudest = channel }
            }
            // -100 dBFS: under it, log10 of the envelopes can give -inf minus -inf.
            guard full[loudest] >= 1e-5 else { continue }
            let cut = min(max(20 * log10(high[loudest] / full[loudest]) + 10, 0), decibels)
            guard cut > 0 else { continue }
            let loss = 1 - pow(10, -cut / 20)
            for channel in block.indices {
                output[channel][frame] = Float(Double(block[channel][frame]) - loss * bands[channel][frame])
            }
        }
        return output
    }

    mutating func finish() -> [[Float]] { filters.map { _ in [] } }

    /// The next value of a peak envelope at `value`.
    private func follow(_ envelope: Double, _ value: Double) -> Double {
        let factor = value > envelope ? attack : release
        return factor * envelope + (1 - factor) * value
    }
}

/// Repair Clipped Peaks (decision 0064 D4), for each channel alone. A candidate is a run of samples
/// of one sign at or over `percent` of the channel peak of the span. A clipped run is each stretch
/// of 3 or more samples of a candidate within max(1e-6 x the candidate level, 2 LSB of
/// `carriedBits`) of the candidate level (its largest magnitude), flat as a clipper leaves them. A
/// candidate over `maxRun` frames (10 ms) stays as it is. The fill is a Hermite cubic with edge
/// slopes from 4 input samples on each side, and a filled sample keeps at least the run level. A run
/// with fewer than 5 frames before it or after it in the span stays as it is.
struct DeclipStage: RenderStage {
    /// `maxRun` + 4: a candidate closes at most `maxRun` frames after its first frame, and its fill
    /// reads 4 frames after the run.
    let latency: Int
    /// The clipped runs that the stage filled.
    private(set) var runs = 0
    var held: Int { channels.first?.output.count ?? 0 }
    private let maxRun: Int
    private let tolerance: Double
    private var channels: [Channel]
    private var taken = 0

    init(percent: Int, peaks: [Float], carriedBits: Int, rate: Double) {
        let delay = Int(rate / 100) + 4
        (maxRun, latency) = (delay - 4, delay)
        tolerance = 2 / Double(1 << (carriedBits - 1))
        channels = peaks.map { peak in
            Channel(level: Double(percent) / 100 * Double(peak), output: Array(repeating: 0, count: delay))
        }
    }

    mutating func process(_ block: [[Float]]) -> [[Float]] {
        let (first, maxRun, tolerance, keep) = (taken, maxRun, tolerance, latency + 5)
        var output: [[Float]] = []
        for index in channels.indices {
            let result = channels[index].process(block[index], from: first, maxRun: maxRun, tolerance: tolerance)
            output.append(result.output)
            runs += result.filled
            channels[index].trim(keep: keep)
        }
        taken += block[0].count
        return output
    }

    /// Gives the held frames. A run still open, or with fewer than 5 frames after it, stays as it is.
    mutating func finish() -> [[Float]] {
        var output: [[Float]] = []
        for index in channels.indices {
            output.append(channels[index].output)
            channels[index].output = []
        }
        return output
    }

    /// The state of one channel. `input` holds the input frames from `inputStart` (the left edge of
    /// a fill reads 5 frames before its run), `output` the frames not given back yet from
    /// `outputStart`, with the fills in them.
    private struct Channel {
        /// The candidate threshold; 0 for a silent channel, which has no candidate.
        let level: Double
        var input: [Float] = []
        var inputStart = 0
        var output: [Float]
        var outputStart: Int
        var open: Int?
        var positive = false
        /// The clipped runs that wait for the 4 frames after them.
        var waiting: [Range<Int>] = []

        init(level: Double, output: [Float]) {
            self.level = level
            self.output = output
            outputStart = -output.count
        }

        func sample(_ frame: Int) -> Double { Double(input[frame - inputStart]) }

        /// Takes `samples` from the frame `first`, and gives as many frames from the front of
        /// `output`, with the number of runs that it filled.
        mutating func process(
            _ samples: [Float], from first: Int, maxRun: Int, tolerance: Double
        ) -> (output: [Float], filled: Int) {
            input += samples
            output += samples
            var filled = 0
            for (offset, value) in samples.enumerated() {
                let frame = first + offset
                let qualifies = level > 0 && Double(abs(value)) >= level
                let over = qualifies && (open == nil || (value > 0) == positive)
                if over, open == nil { (open, positive) = (frame, value > 0) }
                if !over, let start = open {
                    close(start..<frame, maxRun: maxRun, tolerance: tolerance)
                    (open, positive) = (qualifies ? frame : nil, value > 0)
                }
                while let run = waiting.first, run.upperBound + 4 <= frame {
                    fill(run)
                    waiting.removeFirst()
                    filled += 1
                }
            }
            let given = Array(output.prefix(samples.count))
            output.removeFirst(samples.count)
            outputStart += samples.count
            return (given, filled)
        }

        /// Drops the input frames before the last `keep`.
        mutating func trim(keep: Int) {
            let extra = input.count - keep
            guard extra > 0 else { return }
            input.removeFirst(extra)
            inputStart += extra
        }

        /// Queues the clipped runs of `candidate`, a closed candidate.
        mutating func close(_ candidate: Range<Int>, maxRun: Int, tolerance: Double) {
            guard candidate.count >= 3, candidate.count <= maxRun else { return }
            let peak = candidate.reduce(0.0) { max($0, abs(sample($1))) }
            let floor = peak - max(1e-6 * peak, tolerance)
            var start: Int?
            for frame in candidate.lowerBound...candidate.upperBound {
                let flat = frame < candidate.upperBound && abs(sample(frame)) >= floor
                if flat, start == nil { start = frame }
                if !flat, let first = start {
                    if frame - first >= 3, first >= 5 { waiting.append(first..<frame) }
                    start = nil
                }
            }
        }

        /// Fills `run` with the Hermite cubic between the last frame before it (a) and the first
        /// frame after it (b), with the slopes over the 4 frames outside each edge.
        mutating func fill(_ run: Range<Int>) {
            let (a, b) = (run.lowerBound - 1, run.upperBound)
            let span = Double(b - a)
            let (left, right) = (sample(a), sample(b))
            let slopes = ((left - sample(a - 4)) / 4 * span, (sample(b + 4) - right) / 4 * span)
            let level = run.reduce(0.0) { max($0, abs(sample($1))) }
            for frame in run {
                let u = Double(frame - a) / span
                let (square, cube) = (u * u, u * u * u)
                let start: Double = (2 * cube - 3 * square + 1) * left + (cube - 2 * square + u) * slopes.0
                let end: Double = (3 * square - 2 * cube) * right + (cube - square) * slopes.1
                let sign: Double = sample(frame) > 0 ? 1 : -1
                output[frame - outputStart] = Float(sign * max(abs(start + end), level))
            }
        }
    }
}
