import Accelerate
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The voice of the drift tests: a seeded syllable envelope, on for 150 to 400 ms and off for
/// 100 to 600 ms, over seeded sines from 100 to 3400 Hz (log-uniform). Each drawn on or off span
/// has its own 40 sines: one sine set for the whole signal correlates again at lags far from the
/// true lag, under the ratio of the 0076 match rule. A sample is a function of its time in seconds,
/// so a clip at a clock of 1 + m reads the signal at c x (1 + m) / rate with no resampler.
struct DriftSignal {
    private static let sines = 40
    /// The start of each drawn on or off span, in seconds. Span k plays sines 40k..<40(k + 1).
    private let carrier: [Double]
    private let frequencies: [Double]
    private let phases: [Double]
    /// The spans where the envelope is on, in seconds, by start.
    private var speech: [Range<Double>]

    init(seed: UInt64, seconds: Double) {
        var random = SeededGenerator(seed: seed)
        var (speech, carrier, frequencies, phases) = ([Range<Double>](), [Double](), [Double](), [Double]())
        var time = 0.0
        while time < seconds {
            let on = Double.random(in: 0.150...0.400, using: &random)
            let off = Double.random(in: 0.100...0.600, using: &random)
            speech.append(time..<time + on)
            carrier += [time, time + on]
            for _ in 0..<2 * Self.sines {
                let position: Double = Double.random(in: 0..<1, using: &random)
                frequencies.append(100 * pow(34.0, position))
                phases.append(Double.random(in: 0..<(2 * .pi), using: &random))
            }
            time += on + off
        }
        (self.speech, self.carrier, self.frequencies, self.phases) = (speech, carrier, frequencies, phases)
    }

    /// Sets the envelope on (`speech` true) or off in `range` of seconds.
    mutating func set(speech on: Bool, in range: Range<Double>) {
        var spans: [Range<Double>] = []
        for span in speech {
            if span.lowerBound < range.lowerBound {
                spans.append(span.lowerBound..<min(span.upperBound, range.lowerBound))
            }
            if span.upperBound > range.upperBound {
                spans.append(max(span.lowerBound, range.upperBound)..<span.upperBound)
            }
        }
        if on { spans.append(range) }
        speech = spans.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// True when the envelope is on at `time` seconds.
    func speaks(at time: Double) -> Bool { speech.contains { $0.contains(time) } }

    /// `count` samples at the times `start + n x step` seconds. Only the frames where the envelope is
    /// on get sines.
    func samples(start: Double, step: Double, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let end = start + Double(count) * step
        var part = 0
        for span in speech where span.upperBound > start && span.lowerBound < end {
            let on = frames(of: span, start: start, step: step, count: count)
            while part + 1 < carrier.count && carrier[part + 1] <= span.lowerBound { part += 1 }
            var next = part
            while next < carrier.count && carrier[next] < min(span.upperBound, end) {
                let upper = next + 1 < carrier.count ? min(carrier[next + 1], end) : end
                let carried = frames(of: carrier[next]..<upper, start: start, step: step, count: count)
                addSines(of: next, to: &out, in: carried.clamped(to: on), start: start, step: step)
                next += 1
            }
        }
        return out
    }

    /// The indices n of `count` samples whose time `start + n x step` is in `span`.
    private func frames(of span: Range<Double>, start: Double, step: Double, count: Int) -> Range<Int> {
        let low = min(count, max(0, Int(((span.lowerBound - start) / step).rounded(.up))))
        let high = min(count, Int(((span.upperBound - start) / step).rounded(.up)))
        return low..<max(low, high)
    }

    /// Adds the sines of carrier span `part` to `frames` of `out`.
    private func addSines(of part: Int, to out: inout [Float], in frames: Range<Int>, start: Double, step: Double) {
        let block = 4096
        var phase = [Float](repeating: 0, count: block)
        var amplitude: Float = 0.02
        let sines = part * Self.sines..<(part + 1) * Self.sines
        out.withUnsafeMutableBufferPointer { out in
            for first in stride(from: frames.lowerBound, to: frames.upperBound, by: block) {
                let n = min(block, frames.upperBound - first)
                let time = start + Double(first) * step
                for (frequency, offset) in zip(frequencies[sines], phases[sines]) {
                    let turn: Double = 2 * Double.pi
                    let radians: Double = turn * frequency * time + offset
                    var begin = Float(radians.truncatingRemainder(dividingBy: turn))
                    var increment = Float(turn * frequency * step)
                    vDSP_vramp(&begin, &increment, &phase, 1, vDSP_Length(n))
                    var length = Int32(n)
                    phase.withUnsafeMutableBufferPointer { vvsinf($0.baseAddress!, $0.baseAddress!, &length) }
                    let target = out.baseAddress! + first
                    vDSP_vsma(phase, 1, &amplitude, target, 1, target, 1, vDSP_Length(n))
                }
            }
        }
    }
}

/// A package at `rate`: track "ref" holds clip "R" (file "r") that plays a source from session frame
/// 0, and track "c" holds clip "C" (file "c"), a recording of the same source at a clock of 1 + m from
/// source time 30 s. With a pause of `pause` seconds at clip frame `pauseAt`, the clip skips that much
/// source there. The clip starts at session frame 30 s - 1.2345 s, so the true lag of clip frame c is
/// 1.2345 s + m x c, plus the pause from `pauseAt`.
struct DriftPackage {
    let rate: Int
    let length: Int
    let m: Double
    let pauseAt: Int
    let pause: Double
    let offset: Int
    let package: MixPackage

    /// `clip` and `reference` give the samples of a frame range of each file; nil reads `voice`.
    init(
        rate: Int = 48_000, seconds: Double, ppm: Double = 100, pause: Double = 0, at pauseSeconds: Double = 0,
        voice: DriftSignal? = nil, clip: ((DriftPackage, Range<Int>) -> [Float])? = nil,
        reference: ((DriftPackage, Range<Int>) -> [Float])? = nil
    ) throws {
        (self.rate, length, m, self.pause) = (rate, Int(seconds * Double(rate)), ppm * 1e-6, pause)
        pauseAt = Int(pauseSeconds * Double(rate))
        offset = Int(1.2345 * Double(rate))
        package = try MixPackage(sampleRate: rate)
        let voice = voice ?? DriftSignal(seed: 1, seconds: 30 + seconds * 1.01 + pause + 60)
        let referenceLength = Int((sourceTime(Double(length)) + 30) * Double(rate))
        try package.addSignal("r", length: referenceLength) { [self] in
            reference?(self, $0) ?? voice.reference(self, $0)
        }
        try package.addTrack(
            "ref", clip: "R", file: "r", start: 0, offset: 0, length: Frames(referenceLength))
        try package.addSignal("c", length: length) { [self] in clip?(self, $0) ?? voice.clip(self, $0) }
        try package.addTrack(
            "c", clip: "C", file: "c", start: Frames(30 * rate - offset), offset: 0, length: Frames(length))
    }

    /// The source time in seconds of clip frame `c`.
    func sourceTime(_ c: Double) -> Double {
        let played: Double = c * (1 + m) / Double(rate)
        return 30 + played + skipped(c)
    }

    /// The true lag of clip frame `c` in session frames.
    func trueLag(_ c: Double) -> Double {
        let line: Double = Double(offset) + m * c
        return line + skipped(c) * Double(rate)
    }

    /// The seconds of source that the pause skips before clip frame `c`.
    private func skipped(_ c: Double) -> Double { c >= Double(pauseAt) && pause > 0 ? pause : 0 }

    /// The reference frames that clip frames `range` play (before a pause).
    func referenceFrames(of range: Range<Int>) -> Range<Int> {
        Int(
            sourceTime(Double(range.lowerBound)) * Double(rate))..<Int(
                sourceTime(Double(range.upperBound)) * Double(rate))
    }

    /// The clip frames of 60 s cell `index`.
    func cell(_ index: Int) -> Range<Int> { index * 60 * rate..<min(length, (index + 1) * 60 * rate) }

    /// The index of the 60 s cell that holds clip frame `c`.
    func cellIndex(_ c: Double) -> Int { Int(c) / (60 * rate) }

    /// `driftMeasure` of clip "C" to track "ref" in the default span.
    func measure() throws -> DriftMeasure {
        try driftMeasure(
            of: "C", to: "ref", in: package.session, package: package.url,
            span: package.session.syncSpan("C", to: "ref"))
    }

    /// `driftCuts` on the fit of the points of `measure`.
    func cuts() throws -> [Int] {
        let fit = try DriftFit(points: measure().points, sampleRate: Double(rate))
        return try driftCuts(of: "C", to: "ref", in: package.session, package: package.url, fit: fit)
    }

    /// The reference samples of frames `range` from `voice`, with `other` in the reference frames of
    /// the clip cells `replaced` (in place of `voice`) and `added` (on top of `voice`).
    func reference(
        _ range: Range<Int>, voice: DriftSignal, other: DriftSignal, replaced: Set<Int>, added: Set<Int> = []
    ) -> [Float] {
        var samples = voice.reference(self, range)
        for index in replaced.union(added) {
            let frames = referenceFrames(of: cell(index)).clamped(to: range)
            guard !frames.isEmpty else { continue }
            let first = frames.lowerBound - range.lowerBound
            for (k, value) in other.reference(self, frames).enumerated() {
                samples[first + k] = added.contains(index) ? samples[first + k] + value : value
            }
        }
        return samples
    }
}

extension DriftSignal {
    /// The samples of reference frames `range`: the source at session time.
    func reference(_ drift: DriftPackage, _ range: Range<Int>) -> [Float] {
        samples(start: Double(range.lowerBound) / Double(drift.rate), step: 1 / Double(drift.rate), count: range.count)
    }

    /// The samples of clip frames `range`, with the skip of the pause.
    func clip(_ drift: DriftPackage, _ range: Range<Int>) -> [Float] {
        let step = (1 + drift.m) / Double(drift.rate)
        let split = min(max(drift.pauseAt, range.lowerBound), range.upperBound)
        let parts = [range.lowerBound..<split, split..<range.upperBound].filter { !$0.isEmpty }
        return parts.flatMap { part in
            samples(start: drift.sourceTime(Double(part.lowerBound)), step: step, count: part.count)
        }
    }
}

extension MixPackage {
    /// Writes a mono 24-bit WAV of `length` frames in blocks from `samples` and adds it to the pool.
    func addSignal(_ id: FileID, length: Int, samples: (Range<Int>) -> [Float]) throws {
        let path = "\(id.rawValue).wav"
        try writeWAV(
            url.appending(path: "\(clipsFolderName)/\(path)"), rate: session.sampleRate, length: length,
            samples: samples)
        try session.addFile(AudioFile(id: id, path: path, layout: .mono, length: Frames(length)))
    }
}
