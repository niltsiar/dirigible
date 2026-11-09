import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The frame of the centre of step `step` of a group that starts at `first`, rounded down.
private func centre(_ step: Int, first: Int = 0, stepFrames: Int = rideStepFrames) -> Int {
    first + (2 * step + 1) * stepFrames / 2
}

/// The step mean squares of `samples` (one channel each) through a meter that keeps its steps.
private func meterSteps(_ channels: [[Float]]) throws -> [Double] {
    let layout: ChannelLayout = channels.count == 1 ? .mono : .stereo
    var meter = try #require(LoudnessMeter(sampleRate: 48_000, layout: layout, keepsSteps: true))
    meter.feed(try pcmBuffer(channels))
    return try #require(meter.stepMeanSquares)
}

/// Noise with a level in dB at second t: speech has 0.3 s words and 0.1 s gaps at -60 dB.
private func noise(seconds: Int, speech: Bool, seed: UInt64 = 11, level: (Double) -> Double) -> [Float] {
    var generator = SeededGenerator(seed: seed)
    return (0..<seconds * 48_000).map { frame in
        let time = Double(frame) / 48_000
        let gap = speech && time.truncatingRemainder(dividingBy: 0.4) >= 0.3
        return Float.random(in: -0.3...0.3, using: &generator) * Float(pow(10, (gap ? -60 : level(time)) / 20))
    }
}

/// The envelope of clip c1 after `edit`, on a mono session of one clip of `frames`.
private func envelope(frames: Int, _ edit: (inout Session) throws -> Void) throws -> GainEnvelope {
    var session = Session(sampleRate: 48_000)
    try session.addFile(AudioFile(id: "f1", path: "a.wav", layout: .mono, length: Frames(frames)))
    try session.addTrack("t1", name: "T", layout: .mono)
    try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: Frames(frames)), on: "t1")
    try edit(&session)
    return try #require(session.clip("c1")).clip.envelope
}

/// Music-like steps at -20 LUFS +/- 3 dB with an 8 s period, and an envelope of 0 dB with a dip
/// of `depth` dB on steps 300..<500 and 5-step ramps: the dip holds under half the blocks.
private func dipFixture(depth: Double) -> (steps: [Double], envelope: [Double]) {
    let steps = (0..<900).map { Loudness.meanSquare(-20 + 3 * sin(2 * .pi * Double($0) / 80)) }
    let envelope = (0..<900).map { step -> Double in
        if (300..<500).contains(step) { return depth }
        if (295..<300).contains(step) { return depth * Double(step - 294) / 6 }
        if (500..<505).contains(step) { return depth * Double(505 - step) / 6 }
        return 0
    }
    return (steps, envelope)
}

/// The gated integrated loudness of `steps` with `envelope` applied, over only the blocks whose
/// four steps have an envelope gain of `floor` or more (nil: every block).
private func heardReference(_ steps: [Double], _ envelope: [Double], floor: Double?) -> Double? {
    let heard = zip(steps, envelope).map { $0 * pow(10, $1 / 10) }
    let ends = (3..<heard.count).filter { floor == nil || envelope[$0 - 3...$0].min()! >= floor! }
    return Loudness(blocks: ends.map { heard[$0 - 3...$0].reduce(0, +) / 4 }).integrated?.value
}

/// The ride layer criteria of the envelope ride (C4, C7b, C9, C24, C31, C33), on step arrays.
struct RideLayerTests {
    /// C24: the layer is median(0, a, b) at each step. Cases: a = b gives b; a 0.1 and b 5.0 give
    /// 0.1; a 6.0 and b -0.75 give 0; a -6.0 and b -1.0 give -1.0.
    @Test func medianOfTheReadings() {
        let layer = rideLayer(a: [1.5, 0.1, 6.0, -6.0], b: [1.5, 5.0, -0.75, -1.0])
        #expect(layer == [1.5, 0.1, 0, -1.0], "layer \(layer)")
    }

    /// C24: reading a counts in R and o only the blocks where the envelope does not cut against
    /// its mode block gain. A -16 dB and a -5 dB dip under half the blocks: R is the loudness of
    /// the blocks with E >= -0.25 dB. A whole-span gain of -3 dB on top moves R by -3 dB and keeps
    /// o. One envelope gain on the whole span (-10 dB or +6 dB) gives the layer of the source.
    @Test func cutBlocksDoNotSetTheReference() throws {
        for depth in [-16.0, -5.0] {
            let (steps, dip) = dipFixture(depth: depth)
            let a = try #require(LevelRide.standard.heardGains(stepMeanSquares: steps, envelopeDB: dip))
            let expected = try #require(heardReference(steps, dip, floor: -0.25))
            #expect(abs(a.reference - expected) <= 0.001, "\(depth) dB: R \(a.reference), not \(expected)")
            let lowered = try #require(
                LevelRide.standard.heardGains(stepMeanSquares: steps, envelopeDB: dip.map { $0 - 3 }))
            #expect(abs(lowered.reference - (a.reference - 3)) <= 0.001, "\(depth) dB: R \(lowered.reference)")
            #expect(abs(lowered.offset - a.offset) <= 0.001, "\(depth) dB: o \(lowered.offset), not \(a.offset)")
        }
        let (steps, dip) = dipFixture(depth: -5)
        let every = try #require(heardReference(steps, dip, floor: nil))
        let counted = try #require(heardReference(steps, dip, floor: -0.25))
        #expect(abs(every - counted) > 0.05, "control: every block gives \(every) LUFS, not \(counted)")
        let speech = rideSteps([(100, -26), (100, -18)])
        let source = try ride(speech)
        for gain in [-10.0, 6.0] {
            let flat = Array(repeating: gain, count: speech.count)
            let layer = try #require(rideLayer(stepMeanSquares: speech, envelopeDB: flat))
            let largest = zip(layer, source).map { abs($0 - $1) }.max()!
            #expect(largest <= 1e-9, "\(gain) dB on the whole span: the layer differs by \(largest) dB")
        }
        #expect(abs(source[50]) > 1, "control: the curve moves")
    }

    /// C4: with no envelope point, reading a equals reading b, and the layer is the S1 curve.
    @Test func noEnvelopeGivesTheCurve() throws {
        let fixtures = [
            rideSteps([(100, -26), (100, -18)]), rideSteps([(100, -20), (40, -23), (40, -50), (100, -20)]),
            rideSteps([(100, -20), (40, -32), (100, -20)]), words(0.33, lead: 0.037),
        ]
        for steps in fixtures {
            let flat = [Double](repeating: 0, count: steps.count)
            let b = try #require(LevelRide.standard.gains(steps))
            #expect(LevelRide.standard.heardGains(stepMeanSquares: steps, envelopeDB: flat) == b, "a = b")
            let layer = try #require(rideLayer(stepMeanSquares: steps, envelopeDB: flat))
            #expect(zip(layer, b.dB).allSatisfy { abs($0 - $1) <= 1e-9 }, "the layer is the S1 curve")
        }
    }

    /// C9: a stereo source at one constant level gives a layer whose points are all 0 dB within 0.1,
    /// although its steps move with the noise.
    @Test func constantLevelGivesAFlatLayer() throws {
        let channels = [UInt64(12), 13].map { noise(seconds: 20, speech: false, seed: $0) { _ in -10 } }
        let steps = try meterSteps(channels)
        let levels = steps.map(Loudness.lufs)
        #expect(levels.max()! - levels.min()! > 0.2, "control: the steps move by \(levels.max()! - levels.min()!) LU")
        let layer = try #require(rideLayer(stepMeanSquares: steps, envelopeDB: Array(repeating: 0, count: steps.count)))
        let points = GainEnvelope.decimated(dB: layer, first: .zero, stepFrames: rideStepFrames, tolerance: 0.1).points
        #expect(!points.isEmpty && points.allSatisfy { abs($0.gain.dB) <= 0.1 }, "gains \(points.map(\.gain.dB))")
    }

    /// C33: the steps of reading a (the source steps times the envelope power at each step centre)
    /// give a curve within 0.1 dB of a meter that reads the samples with the envelope applied: a
    /// +6 dB lift on a -10 dB passage of speech, the same lift with a 1-frame ramp, and the default
    /// duck on music.
    @Test func envelopeScaleMatchesTheSampleRead() throws {
        let speech = noise(seconds: 60, speech: true) { (20..<35).contains($0) ? -10 : 0 }
        let music = noise(seconds: 90, speech: false) { -3 + 3 * sin(2 * .pi * $0 / 8) }
        let lift = Frames(20 * 48_000)..<Frames(35 * 48_000)
        let fixtures: [(name: String, samples: [Float], envelope: GainEnvelope)] = [
            (
                "lift", speech,
                try envelope(frames: speech.count) {
                    try $0.changeGain(
                        by: Gain(dB: 6)!, in: lift, on: ["t1"],
                        ramp: $0.gainRamp)
                }
            ),
            (
                "lift, 1-frame ramp", speech,
                try envelope(frames: speech.count) {
                    try $0.changeGain(
                        by: Gain(dB: 6)!, in: lift, on: ["t1"], ramp: .zero
                    )
                }
            ),
            (
                "duck", music,
                try envelope(frames: music.count) {
                    let runs = [Frames(20 * 48_000)..<Frames(40 * 48_000), Frames(55 * 48_000)..<Frames(70 * 48_000)]
                    try $0.duck(runs: runs, shape: .defaults(sampleRate: 48_000), music: ["t1"], scope: nil)
                }
            ),
        ]
        for fixture in fixtures {
            var factors = [Float](repeating: 0, count: fixture.samples.count)
            var scratch = factors
            factors.withUnsafeMutableBufferPointer { factors in
                scratch.withUnsafeMutableBufferPointer {
                    envelopeFactors([fixture.envelope], from: .zero, decibels: 0, into: factors, scratch: $0)
                }
            }
            let source = try meterSteps([fixture.samples])
            let enveloped = try meterSteps([zip(fixture.samples, factors).map(*)])
            let gains = source.indices.map { fixture.envelope.gain(at: Frames(centre($0))) }
            let floor = LevelRide.modeBlockGain(gains) - 0.25
            let a = try #require(LevelRide.standard.heardGains(stepMeanSquares: source, envelopeDB: gains)).dB
            let read = try #require(LevelRide.standard.gains(enveloped, counting: gains.map { $0 >= floor })).dB
            let largest = zip(a, read).map { abs($0 - $1) }.max()!
            #expect(largest <= 0.1, "\(fixture.name): the one-meter reading differs by \(largest) dB")
            let b = try ride(source)
            #expect(zip(a, b).map { abs($0 - $1) }.max()! > 1, "control: \(fixture.name) changes reading a")
        }
    }

    /// C31: at each step centre the layer is within 0.1 dB of the step curve, each gain is a
    /// multiple of 0.01 dB, and the layer has fewer points than steps. Seeded random walks, also
    /// with an odd step length; a tolerance of 0.5 dB fails the first clause.
    @Test(arguments: [(UInt64(1), 4_800), (UInt64(2), 4_799), (UInt64(3), 4_410)])
    func decimationHoldsTheTolerance(seed: UInt64, stepFrames: Int) {
        var generator = SeededGenerator(seed: seed)
        var walk = [Double.random(in: -6...6, using: &generator)]
        for _ in 1..<3_000 {
            let move = Double.random(in: 0..<1, using: &generator) < 0.02 ? 3.0 : 0.08
            walk.append(min(6, max(-6, walk.last! + Double.random(in: -move...move, using: &generator))))
        }
        let first = 1_234_567
        let layer = GainEnvelope.decimated(dB: walk, first: Frames(first), stepFrames: stepFrames, tolerance: 0.1)
        let errors = walk.indices.map {
            abs(layer.gain(at: Frames(centre($0, first: first, stepFrames: stepFrames))) - walk[$0])
        }
        #expect(errors.max()! <= 0.1 + 1e-12, "seed \(seed): an error of \(errors.max()!) dB")
        let onGrid = layer.points.allSatisfy { abs($0.gain.dB * 100 - ($0.gain.dB * 100).rounded()) <= 1e-9 }
        #expect(onGrid, "seed \(seed): a gain off the 0.01 dB grid")
        #expect(
            layer.points.count < walk.count / 2, "seed \(seed): \(layer.points.count) points for \(walk.count) steps")
    }

    /// C31: a flat run of steps gives two points, at the first and the last step centre.
    @Test func flatRunGivesTwoPoints() {
        let layer = GainEnvelope.decimated(
            dB: Array(repeating: 1.237, count: 100), first: Frames(1_000), stepFrames: rideStepFrames, tolerance: 0.1)
        let points = layer.points.map { ($0.frame.count, $0.gain.dB) }
        #expect(points.count == 2 && points[0] == (3_400, 1.24) && points[1] == (478_600, 1.24), "points \(points)")
        #expect(GainEnvelope.decimated(dB: [], first: .zero, stepFrames: rideStepFrames, tolerance: 0.1).isEmpty)
    }

    /// C7b: a 1 LU level step at frame 480 000, read through the layer: the gain is halfway between
    /// its plateaus about 0.32 step before the frame for a rise in level, and 0.32 step after it for
    /// a fall. With a tolerance of 0 the layer keeps each step, so the test reads the anchor.
    @Test(arguments: [(-20.0, -19.0, 478_500), (-19.0, -20.0, 481_500)])
    func levelStepCentresOnItsFrame(before: Double, after: Double, halfway: Int) throws {
        let steps = rideSteps([(100, before), (100, after)])
        let curve = try #require(rideLayer(stepMeanSquares: steps, envelopeDB: Array(repeating: 0, count: 200)))
        let layer = GainEnvelope.decimated(dB: curve, first: .zero, stepFrames: rideStepFrames, tolerance: 0)
        let middle = (curve[50] + curve[150]) / 2
        let rising = curve[150] > curve[50]
        let frame = try #require(
            (450_000..<510_000).first {
                let gain = layer.gain(at: Frames($0))
                return rising ? gain >= middle : gain <= middle
            })
        #expect(abs(frame - halfway) <= 1_200, "halfway at frame \(frame), not near \(halfway)")
    }

    /// C7b: the layer holds the first and the last step centre of the group; before the first
    /// centre it has the first gain, and after the last centre the last gain, up to the last frame
    /// of a window with a partial last step.
    @Test func layerCoversTheWindow() throws {
        let steps = rideSteps([(100, -26), (100, -18)])
        let curve = try #require(rideLayer(stepMeanSquares: steps, envelopeDB: Array(repeating: 0, count: 200)))
        let first = 7_000
        let layer = GainEnvelope.decimated(dB: curve, first: Frames(first), stepFrames: rideStepFrames, tolerance: 0.1)
        let (head, tail) = (try #require(layer.points.first), try #require(layer.points.last))
        #expect(head.frame.count == first + 2_400 && tail.frame.count == first + 199 * 4_800 + 2_400)
        #expect(
            layer.gain(at: Frames(first)) == head.gain.dB
                && layer.gain(at: Frames(first + 200 * 4_800 + 3_000)) == tail.gain.dB)
        #expect(abs(head.gain.dB - tail.gain.dB) > 1, "control: the edge gains differ")
    }
}
