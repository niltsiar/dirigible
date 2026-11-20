import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Criteria C3 and C4 of the stem export (U4): each stem is the `exportMix` of its own tracks over
/// the plan range, so the stems start at the range start and add up to the mix.
struct ExportStemsTests {
    /// One LSB of a 24-bit file at full scale.
    static let lsb = 1.0 / 8_388_608

    /// Seeded noise from -`peak` to `peak`.
    static func noise(_ frames: Int, peak: Float, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<frames).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int(state >> 41) - 4_194_304) / 4_194_304 * peak
        }
    }

    /// Three tracks of noise over 0..<144000, each under -10 dBFS after all its gains:
    /// t1 with a track gain, a clip gain, fades, and a gain envelope; t2 with two clips, a
    /// crossfade at their join, and a ride layer on the first clip; t3 with a voice match.
    static func mixedPackage() throws -> MixPackage {
        let package = try MixPackage()
        try package.addFile("n1", channels: [noise(144_000, peak: 0.2, seed: 1)])
        try package.addFile("n2", channels: [noise(200_000, peak: 0.2, seed: 2)])
        try package.addFile("n3", channels: [noise(144_000, peak: 0.15, seed: 3)])
        try package.session.addTrack("t1", name: "t1", layout: .mono)
        try package.session.place(
            Clip(
                id: "a", file: "n1", start: 4_800, offset: 0, length: 120_000, gain: #require(Gain(dB: -2)),
                fades: #require(Fades(fadeIn: 4_800, fadeOut: 9_600))), on: "t1")
        try package.session.setEnvelope(
            [24_000: .zero, 48_000: #require(Gain(dB: -6)), 72_000: #require(Gain(dB: 2))], clip: "a")
        try package.session.setGain(#require(Gain(dB: -3)), track: "t1")
        let cut = try #require(Gain(dB: -4))
        let ride = try #require(GainEnvelope([.init(frame: 30_000, gain: cut), .init(frame: 60_000, gain: .zero)]))
        try package.session.addTrack("t2", name: "t2", layout: .mono)
        try package.session.place(
            Clip(id: "b1", file: "n2", start: 0, offset: 20_000, length: 60_000, ride: ride), on: "t2")
        try package.session.place(Clip(id: "b2", file: "n2", start: 60_000, offset: 100_000, length: 60_000), on: "t2")
        try package.session.setCrossfades(["b1": 4_800])
        try package.addTrack("t3", clip: "c", file: "n3", start: 24_000, offset: 0, length: 100_000)
        try package.session.setMatch([
            "t3": VoiceMatch(
                amount: #require(VoiceMatch.Amount(100)), reference: "Host 01",
                curve: (0..<25).map { -3 + 0.25 * Double($0) }, targetPowers: [Double](repeating: 1, count: 25))
        ])
        return package
    }

    /// The samples of the `exportMix` of `tracks` over `range`, written to `name` in the package
    /// folder.
    static func export(
        _ package: MixPackage, _ tracks: Set<TrackID>, _ range: Range<Frames>, _ options: ExportOptions,
        _ name: String
    ) throws -> [Float] {
        let url = package.folder.url.appending(path: name)
        let source = try #require(ExportSource(range: range, tracks: tracks))
        _ = try exportMix(package.session, source: source, options: options, to: url, package: { package.url })
        return try readAudio(url).samples
    }

    /// C4: the sample sum of the 24-bit track stems equals the 24-bit mix of the same range and
    /// tracks within n + 1 LSB (W2).
    @Test func theStemsAddUpToTheMix() throws {
        let package = try Self.mixedPackage()
        let tracks: Set<TrackID> = ["t1", "t2", "t3"]
        let plan = package.session.stemPlan(by: .track, tracks: tracks, range: 0..<144_000)
        #expect(plan.stems.map(\.key) == [.track("t1"), .track("t2"), .track("t3")])
        let options = ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .session)
        let stems = try plan.stems.enumerated().map { index, stem in
            try Self.export(package, stem.tracks, plan.range, options, "\(index + 1).wav")
        }
        let mix = try Self.export(package, tracks, 0..<144_000, options, "mix.wav")
        let peaks = stems.map { $0.map(abs).max() ?? 0 }
        #expect(peaks.allSatisfy { $0 > 0.05 && $0 < 0.316 }, "stem peaks \(peaks)")
        #expect(stems.allSatisfy { $0.count == mix.count } && mix.count == 2 * 144_000)
        let error = mix.indices.map { k in abs(stems.reduce(0.0) { $0 + Double($1[k]) } - Double(mix[k])) }.max() ?? 0
        let bound = Double(plan.stems.count + 1) * Self.lsb
        #expect(error <= bound, "sum error \(error / Self.lsb) LSB, bound \(bound / Self.lsb) LSB")
    }

    /// C3: with the range 48000..<144000, a clip at 96000 starts at file frame 48000 of its stem,
    /// and a clip at 48000 sounds at file frame 0. Every file has the range length, also at 44.1 kHz.
    @Test func everyStemStartsAtTheRangeStartWithTheRangeLength() throws {
        let package = try MixPackage()
        try package.addFile("n1", channels: [Self.noise(24_000, peak: 0.2, seed: 1)])
        try package.addFile("n2", channels: [Self.noise(24_000, peak: 0.2, seed: 2)])
        try package.addTrack("late", clip: "a", file: "n1", start: 96_000, offset: 0, length: 24_000)
        try package.addTrack("early", clip: "b", file: "n2", start: 48_000, offset: 0, length: 24_000)
        let plan = package.session.stemPlan(by: .track, tracks: nil, range: 48_000..<144_000)
        #expect(plan.stems.map(\.key) == [.track("late"), .track("early")])
        let session = ExportOptions(format: .wav(.bits24), layout: .mono, rate: .session)
        let files = try plan.stems.enumerated().map { index, stem in
            try Self.export(package, stem.tracks, plan.range, session, "\(index + 1).wav")
        }
        #expect(files.map(\.count) == [96_000, 96_000])
        if files.count == 2 {
            #expect(files[0][0..<48_000].allSatisfy { $0 == 0 }, "the late stem is silent before its clip")
            #expect((files[0][48_000..<48_480].map(abs).max() ?? 0) > 0.01, "the late stem sounds at 48000")
            #expect((files[1][0..<480].map(abs).max() ?? 0) > 0.01, "the early stem sounds at frame 0")
        }
        let rate = ExportOptions(format: .wav(.bits24), layout: .mono, rate: .hz44100)
        let counts = try plan.stems.enumerated().map { index, stem in
            try Self.export(package, stem.tracks, plan.range, rate, "\(index + 1)-44.wav").count
        }
        #expect(counts.count == 2 && Set(counts).count == 1 && abs((counts.first ?? 0) - 88_200) <= 1, "\(counts)")
    }
}
