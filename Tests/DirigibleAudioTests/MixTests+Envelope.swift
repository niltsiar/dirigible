import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The gain envelope in the mix (decision 0060, C5 and C8).
extension MixTests {
    /// The gain in dB of `points` at the file frame `frame`, in Double: linear between two points,
    /// held outside them, 0 with no point.
    static func decibels(_ points: [GainEnvelope.Point], at frame: Int) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if frame <= first.frame.count { return first.gain.dB }
        if frame >= last.frame.count { return last.gain.dB }
        let right = points.firstIndex { $0.frame.count > frame }!
        let (a, b) = (points[right - 1], points[right])
        return a.gain.dB + (b.gain.dB - a.gain.dB) * Double(frame - a.frame.count) / Double((b.frame - a.frame).count)
    }

    /// The envelope of `points`, each a file frame and a gain in dB.
    static func envelope(_ points: [(Int, Double)]) throws -> GainEnvelope {
        var list: [GainEnvelope.Point] = []
        for (frame, dB) in points {
            list.append(GainEnvelope.Point(frame: Frames(frame), gain: try #require(Gain(dB: dB))))
        }
        return try #require(GainEnvelope(list))
    }

    /// The crossfade fixture of `crossfadedPackage` with an envelope, a gain, and an outer fade on A
    /// and B: A alone on the left channel, B alone on the right channel, each a DC 1 signal, so a
    /// channel is the gain of its clip at each frame.
    static func envelopedPackage(
        envelopes: (GainEnvelope, GainEnvelope), gains: (Gain, Gain), fades: (Int, Int), crossfade: Int, track: Gain
    ) throws -> MixPackage {
        let package = try MixPackage()
        let (one, zero) = ([Float](repeating: 1, count: 30_000), [Float](repeating: 0, count: 30_000))
        try package.addFile("left", channels: [one, zero])
        try package.addFile("right", channels: [zero, one])
        try package.session.addTrack("t1", name: "t1", layout: .stereo)
        try package.session.place(
            Clip(
                id: "A", file: "left", start: 1_000, offset: 5_000, length: 10_000, gain: gains.0,
                fades: #require(Fades(fadeIn: Frames(fades.0), fadeOut: 0)), envelope: envelopes.0), on: "t1")
        try package.session.place(
            Clip(
                id: "B", file: "right", start: 11_000, offset: 5_000, length: 10_000, gain: gains.1,
                fades: #require(Fades(fadeIn: 0, fadeOut: Frames(fades.1))), envelope: envelopes.1), on: "t1")
        try package.session.setCrossfades(["A": Frames(crossfade)])
        try package.session.setGain(track, track: "t1")
        return package
    }

    /// The expected mix of `range` in Double: each sounding clip of t1 on its channel, the clip and
    /// track gain times `Fades.gain` times 10^(dB/20) of its envelope at the file frame.
    static func envelopedMix(_ session: Session, _ range: Range<Int>) throws -> [[Double]] {
        let track = try #require(session.track("t1"))
        let sounding = track.clips.sounding(in: Frames(range.lowerBound)..<Frames(range.upperBound))
        return try ["A", "B"].map { id in
            let edges = try #require(sounding.first { $0.clip.id == ClipID(id) })
            let clip = edges.clip
            return range.map { t in
                guard clip.range.contains(Frames(t)) else { return 0 }
                let k = t - clip.start.count
                let dB = clip.gain.dB + track.gain.dB + decibels(clip.envelope.points, at: clip.offset.count + k)
                return pow(10, dB / 20) * clip.fades.gain(at: Frames(k), length: clip.length, curves: edges.curves)
            }
        }
    }

    /// The largest error in dB of `out` against `expected`, and its frame. A frame where the
    /// expected gain is 0 must be 0.
    static func decibelError(_ out: [Float], _ expected: [Double]) -> (dB: Double, frame: Int) {
        var worst = (dB: 0.0, frame: -1)
        for (k, (value, reference)) in zip(out, expected).enumerated() {
            let error = reference == 0 ? (value == 0 ? 0 : .infinity) : abs(20 * log10(Double(value) / reference))
            if !(error <= worst.dB) { worst = (error.isNaN ? .infinity : error, k) }
        }
        return out.count == expected.count ? worst : (.infinity, -1)
    }

    /// C5: seeded envelopes with points inside and outside the clip windows, clip and track gains,
    /// outer fades, and a crossfade. One reader renders the mix in parts of seeded sizes, and the
    /// offline Player plays it: each frame is within 1e-4 dB of the Double reference. A literal case
    /// gives -8 dB in the middle of a ramp from 0 dB to -16 dB.
    @Test func theEnvelopeRendersLinearInDecibels() async throws {
        let range = 0..<22_000
        for seed in [1, 2, 3] as [UInt64] {
            var random = SeededGenerator(seed: seed)
            func randomEnvelope(_ counts: ClosedRange<Int>) throws -> GainEnvelope {
                let frames = Set(
                    (0..<Int.random(in: counts, using: &random)).map { _ in Int.random(in: 0...30_000, using: &random) }
                )
                return try Self.envelope(frames.sorted().map { ($0, Double.random(in: -30...12, using: &random)) })
            }
            let package = try Self.envelopedPackage(
                envelopes: (randomEnvelope(1...8), randomEnvelope(0...8)),
                gains: (
                    #require(Gain(dB: .random(in: -12...6, using: &random))),
                    #require(Gain(dB: .random(in: -12...6, using: &random)))
                ),
                fades: (.random(in: 0...3_000, using: &random), .random(in: 0...3_000, using: &random)),
                crossfade: 2 * .random(in: 1...2_000, using: &random),
                track: #require(Gain(dB: .random(in: -6...6, using: &random))))
            let expected = try Self.envelopedMix(package.session, range)

            let reader = package.reader()
            var parts: [[Float]] = [[], []]
            var start = range.lowerBound
            while start < range.upperBound {
                let end = min(range.upperBound, start + .random(in: 1...6_000, using: &random))
                let part = try package.render(reader, Frames(start)..<Frames(end))
                for channel in 0..<2 { parts[channel] += part[channel] }
                start = end
            }
            for channel in 0..<2 {
                let error = Self.decibelError(parts[channel], expected[channel])
                #expect(error.dB <= 1e-4, "seed \(seed), channel \(channel): \(error.dB) dB at frame \(error.frame)")
            }

            let url = package.url
            let player = Player(package: { url }, output: .offline, session: package.session)
            await player.apply(.play(from: 1_000, shuttle: Shuttle(direction: .forward, rate: .one)), number: 1)
            let played = await player.renderOffline(frames: 19_200)
            for channel in 0..<2 {
                let error = Self.decibelError(played[channel], Array(expected[channel][1_000..<20_200]))
                #expect(
                    error.dB <= 1e-4, "seed \(seed), channel \(channel) played: \(error.dB) dB at frame \(error.frame)")
            }
        }

        let package = try Self.envelopedPackage(
            envelopes: (Self.envelope([(6_000, 0), (10_000, -16)]), .empty), gains: (.zero, .zero), fades: (0, 0),
            crossfade: 0, track: .zero)
        let middle = try package.mix(4_000..<4_001)[0][0]
        #expect(
            abs(20 * log10(Double(middle)) + 8) <= 1e-4,
            "file frame 8000 of a ramp from 0 to -16 dB: \(20 * log10(Double(middle))) dB")
    }

    /// C5: a part at the end of a segment of 2^30 frames is within 1e-4 dB of the Double line, so
    /// no file frame above 2^24 becomes a Float.
    @Test func aPartAtTheEndOfALongSegmentIsExact() throws {
        let length = 1 << 30
        let envelope = try Self.envelope([(0, 6), (length, -30)])
        for from in [length - 4_800, length - 30_001] {
            var factors = [Float](repeating: 0, count: 4_800)
            factors.withUnsafeMutableBufferPointer {
                envelopeFactors(envelope, from: Frames(from), decibels: -3, into: $0)
            }
            let error = (0..<4_800).map { k in
                abs(20 * log10(Double(factors[k])) - (-3 + Self.decibels(envelope.points, at: from + k)))
            }.max()!
            #expect(error <= 1e-4, "a part from \(from): \(error) dB")
        }
    }

    #if DEBUG
        /// C8: a part of a clip with no envelope point reads no envelope, with or without a fade. A
        /// clip with a point reads it once per part.
        @Test func aClipWithNoEnvelopeKeepsTheOneGainPath() throws {
            let faded = try fadedPackage()
            let plain = faded.reader()
            _ = try faded.render(plain, 0..<7_000)
            #expect(plain.envelopeParts == 0, "a plain clip and a faded clip read no envelope")

            let package = try Self.envelopedPackage(
                envelopes: (Self.envelope([(6_000, 0), (10_000, -16)]), .empty), gains: (.zero, .zero),
                fades: (480, 0), crossfade: 0, track: .zero)
            let reader = package.reader()
            _ = try package.render(reader, 0..<22_000)
            #expect(reader.envelopeParts == 1, "A reads its envelope and B has none: \(reader.envelopeParts)")
        }
    #endif
}
