import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The two gain layers of a clip in the mix (decision 0060): the envelope and the ride add in
/// dB, on the crossfade fixture of `MixTests.envelopedPackage` (A on the left channel, B on the
/// right channel, each a DC 1 signal).
struct MixLayersTests {
    /// A seeded layer of `counts` points at file frames 0 ... 30,000, each of a gain in `range` dB.
    static func randomLayer(
        _ counts: ClosedRange<Int>, dB range: ClosedRange<Double>, using random: inout SeededGenerator
    ) throws -> GainEnvelope {
        let frames = Set(
            (0..<Int.random(in: counts, using: &random)).map { _ in Int.random(in: 0...30_000, using: &random) })
        return try MixTests.envelope(frames.sorted().map { ($0, Double.random(in: range, using: &random)) })
    }

    /// The largest relative error of `out` against `expected`. A frame where the expected value is
    /// 0 must be 0.
    static func relativeError(_ out: [Float], _ expected: [Double]) -> (error: Double, frame: Int) {
        var worst = (error: 0.0, frame: -1)
        for (k, (value, reference)) in zip(out, expected).enumerated() {
            let error = reference == 0 ? (value == 0 ? 0 : .infinity) : abs(Double(value) / reference - 1)
            if !(error <= worst.error) { worst = (error.isNaN ? .infinity : error, k) }
        }
        return out.count == expected.count ? worst : (.infinity, -1)
    }

    /// A has an envelope and a ride, B has a ride only, with clip and track gains, outer fades,
    /// and a crossfade. One reader renders the mix in parts of seeded sizes, and the offline Player
    /// plays it: each frame is 10^((clip gain + track gain + envelope + ride) / 20) times the fade
    /// factor within 1e-5 relative.
    @Test func factorsAddTheLayers() async throws {
        let range = 0..<22_000
        for seed in [1, 2, 3] as [UInt64] {
            var random = SeededGenerator(seed: seed)
            let envelope = try Self.randomLayer(1...8, dB: -30...12, using: &random)
            let package = try MixTests.envelopedPackage(
                envelopes: (envelope, .empty),
                gains: (
                    #require(Gain(dB: .random(in: -12...6, using: &random))),
                    #require(Gain(dB: .random(in: -12...6, using: &random)))
                ),
                fades: (.random(in: 0...3_000, using: &random), .random(in: 0...3_000, using: &random)),
                crossfade: 2 * .random(in: 1...2_000, using: &random),
                track: #require(Gain(dB: .random(in: -6...6, using: &random))))
            try package.session.setRides([
                "A": Self.randomLayer(1...40, dB: -6...6, using: &random),
                "B": Self.randomLayer(1...40, dB: -6...6, using: &random),
            ])
            let expected = try MixTests.envelopedMix(package.session, range)

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
                let error = Self.relativeError(parts[channel], expected[channel])
                #expect(error.error <= 1e-5, "seed \(seed), channel \(channel): \(error.error) at frame \(error.frame)")
            }

            let url = package.url
            let player = Player(package: { url }, output: .offline, session: package.session)
            await player.apply(.play(from: 1_000, shuttle: Shuttle(direction: .forward, rate: .one)), number: 1)
            let played = await player.renderOffline(frames: 19_200)
            for channel in 0..<2 {
                let error = Self.relativeError(played[channel], Array(expected[channel][1_000..<20_200]))
                #expect(
                    error.error <= 1e-5, "seed \(seed), channel \(channel) played: \(error.error) at \(error.frame)")
            }
        }
    }

    #if DEBUG
        /// A part with no point in either layer and no fade keeps the one-gain path, and a clip
        /// with only a ride reads its layers once per part and plays the ride.
        @Test func noLayerKeepsTheOneGainPath() throws {
            let package = try MixPackage()
            try package.addFile("f1", channels: [[Float](repeating: 0.5, count: 9_600)])
            try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 9_600)
            let plain = package.reader()
            let flat = try package.render(plain, 0..<9_600)
            #expect(plain.envelopeParts == 0, "a clip with no layer point reads no layer")
            #expect(flat[0].allSatisfy { $0 == 0.5 }, "the one-gain path plays the source")

            try package.session.setRides(["c1": MixTests.envelope([(0, 0), (9_600, -6)])])
            let ridden = package.reader()
            let out = try package.render(ridden, 0..<9_600)
            #expect(ridden.envelopeParts == 1, "a clip with a ride reads its layers: \(ridden.envelopeParts)")
            let expected = (0..<9_600).map { 0.5 * pow(10, -6 * Double($0) / 9_600 / 20) }
            let error = Self.relativeError(out[0], expected)
            #expect(error.error <= 1e-5, "the ride plays: \(error.error) at frame \(error.frame)")
        }
    #endif

    /// A stereo clip has one ride for both channels. The right channel is half the left
    /// channel in the source, and stays half of it after both layers; the left channel has the
    /// gain of the two layers.
    @Test func channelsShareTheLayers() throws {
        let left = ExportTests.noise(frames: 12_000, seed: 7)
        let package = try MixPackage()
        try package.addFile("f1", channels: [left, left.map { $0 / 2 }])
        try package.addTrack("t1", layout: .stereo, clip: "c1", file: "f1", start: 0, offset: 0, length: 12_000)
        let (envelope, ride) = try (
            MixTests.envelope([(2_000, 0), (6_000, -10)]), MixTests.envelope([(0, 4), (9_000, -4), (11_000, 2)])
        )
        try package.session.setEnvelopes(["c1": envelope])
        try package.session.setRides(["c1": ride])

        let out = try package.mix(0..<12_000)
        let halves = zip(out[0], out[1]).map { abs($0 / 2 - $1) }.max()!
        #expect(halves <= 1e-6, "the right channel is half the left channel: \(halves)")
        let expected = left.indices.map { k in
            Double(left[k])
                * pow(10, (MixTests.decibels(envelope.points, at: k) + MixTests.decibels(ride.points, at: k)) / 20)
        }
        let error = Self.relativeError(out[0], expected)
        #expect(error.error <= 1e-5, "the left channel has both layers: \(error.error) at frame \(error.frame)")
    }
}
