import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Criteria C3, C4, and C15 of the stem export: each stem is the `exportMix` of its own tracks
/// over the plan range, so the stems start at the range start and add up to the mix.
struct ExportStemsTests {
    static let wav24 = StemOptions(format: .wav(.bits24), layout: .stereo, rate: .session)
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

    /// Exports the stems of `tracks` over `range` to the folder `name` in the test folder.
    static func stems(
        _ package: MixPackage, by grouping: StemGrouping = .track, tracks: Set<TrackID>? = nil, range: Range<Frames>,
        options: StemOptions = wav24, name: String = "stems"
    ) throws -> StemsResult {
        try exportStems(
            package.session, by: grouping, source: #require(ExportSource(range: range, tracks: tracks)),
            titles: .english, options: options, to: package.folder.url.appending(path: name),
            package: { package.url }, progress: { _ in }, isCancelled: { false })
    }

    /// The samples of each stem file of `result`, in plan order.
    static func samples(of result: StemsResult, in folder: URL) throws -> [[Float]] {
        try result.files.map { try readAudio(folder.appending(path: $0.name)).samples }
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

    /// Adds a track with one clip of a mono 32-bit float CAF, which keeps samples at and over full
    /// scale, at unity gain.
    static func addFloatTrack(_ package: MixPackage, _ id: TrackID, _ samples: [Float]) throws {
        let path = "\(id.rawValue).caf"
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Double(package.session.sampleRate), channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData![0].update(from: samples, count: samples.count)
        do {
            let file = try AVAudioFile(
                forWriting: package.url.appending(path: "\(clipsFolderName)/\(path)"), settings: format.settings,
                commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        let length = Frames(samples.count)
        let file = FileID(id.rawValue)
        try package.session.addFile(AudioFile(id: file, path: path, layout: .mono, length: length))
        try package.addTrack(id, clip: ClipID(id.rawValue), file: file, start: 0, offset: 0, length: length)
    }

    /// C4: the sample sum of the 24-bit track stems, and of the 24-bit role stems (t1 and t3
    /// dialogue, t2 no role), equals the 24-bit mix of the same range and tracks within n + 1 LSB
    /// (W2). The stem peaks sum under 1.0, so no mix peak is measured.
    @Test(arguments: [StemGrouping.track, .role]) func theStemsAddUpToTheMix(by grouping: StemGrouping) throws {
        let package = try Self.mixedPackage()
        try package.session.setRole(.dialogue, tracks: ["t1", "t3"])
        let tracks: Set<TrackID> = ["t1", "t2", "t3"]
        let result = try Self.stems(package, by: grouping, tracks: tracks, range: 0..<144_000)
        switch grouping {
        case .track:
            #expect(result.plan.stems.map(\.key) == [.track("t1"), .track("t2"), .track("t3")])
            #expect(result.files.map(\.name) == ["01 t1.wav", "02 t2.wav", "03 t3.wav"])
        case .role:
            #expect(result.plan.stems.map(\.key) == [.role(.dialogue), .role(nil)])
            #expect(result.files.map(\.name) == ["Dialogue.wav", "No Role.wav"])
        }
        let stems = try Self.samples(of: result, in: package.folder.url.appending(path: "stems"))
        let options = ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .session)
        let mix = try Self.export(package, tracks, 0..<144_000, options, "mix.wav")
        let peaks = stems.map { $0.map(abs).max() ?? 0 }
        #expect(peaks.allSatisfy { $0 > 0.05 } && peaks.reduce(0, +) < 0.95, "stem peaks \(peaks)")
        #expect(result.files.map(\.samplePeak).allSatisfy { $0 > 0.05 })
        #expect(result.mixPeak == nil)
        #expect(
            stems.count == result.plan.stems.count && stems.allSatisfy { $0.count == mix.count }
                && mix.count == 2 * 144_000)
        let error = mix.indices.map { k in abs(stems.reduce(0.0) { $0 + Double($1[k]) } - Double(mix[k])) }.max() ?? 0
        let bound = Double(result.plan.stems.count + 1) * Self.lsb
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
        let mono = StemOptions(format: .wav(.bits24), layout: .mono, rate: .session)
        let result = try Self.stems(package, range: 48_000..<144_000, options: mono)
        #expect(result.plan.stems.map(\.key) == [.track("late"), .track("early")])
        let files = try Self.samples(of: result, in: package.folder.url.appending(path: "stems"))
        #expect(files.map(\.count) == [96_000, 96_000])
        if files.count == 2 {
            #expect(files[0][0..<48_000].allSatisfy { $0 == 0 }, "the late stem is silent before its clip")
            #expect((files[0][48_000..<48_480].map(abs).max() ?? 0) > 0.01, "the late stem sounds at 48000")
            #expect((files[1][0..<480].map(abs).max() ?? 0) > 0.01, "the early stem sounds at frame 0")
        }
        let rate = StemOptions(format: .wav(.bits24), layout: .mono, rate: .hz44100)
        let resampled = try Self.stems(package, range: 48_000..<144_000, options: rate, name: "stems-44")
        let counts = try Self.samples(of: resampled, in: package.folder.url.appending(path: "stems-44")).map(\.count)
        #expect(counts.count == 2 && Set(counts).count == 1 && abs((counts.first ?? 0) - 88_200) <= 1, "\(counts)")
    }

    /// C15 fixture A: a stem with a sample of `Float(1).nextUp` is over full scale; a stem with a
    /// peak of exactly 1.0 is not. The stem peaks sum over 1.0, so the mix peak is measured.
    @Test func aStemOverFullScaleIsNamedAndTheSumIsNotClaimed() throws {
        let package = try MixPackage()
        try Self.addFloatTrack(package, "over", [0.25, Float(1).nextUp, 0.25, 0, 0, 0])
        try Self.addFloatTrack(package, "full", [0, 0, 0, 0.25, 1, 0.25])
        let result = try Self.stems(package, range: 0..<6)
        #expect(result.files.map(\.samplePeak) == [Float(1).nextUp, 1])
        #expect(result.files.map(\.isOverFullScale) == [true, false])
        #expect(result.mixPeak == Float(1).nextUp)
    }

    /// C15 fixture B: each stem is at or under 1.0, and their sum clips: no stem is over full
    /// scale, and the mix peak is over 1.0.
    @Test func aMixOverFullScaleWithNoStemOverGivesTheMixLine() throws {
        let package = try MixPackage()
        try Self.addFloatTrack(package, "a", [0, 0.75, 0.5, 0])
        try Self.addFloatTrack(package, "b", [0, 0.75, -0.5, 0])
        let result = try Self.stems(package, range: 0..<4)
        #expect(result.files.map(\.isOverFullScale) == [false, false])
        #expect(result.mixPeak == 1.5)
    }

    /// C8: a track name longer than the limit gives a FLAC stem whose name is `exportNameLimit`
    /// bytes, and it exports.
    @Test func aFLACStemAtTheLongestNameExports() throws {
        let package = try MixPackage()
        try package.addFile("n1", channels: [Self.noise(4_800, peak: 0.2, seed: 1)])
        try package.session.addTrack("t1", name: String(repeating: "a", count: 250), layout: .mono)
        try package.session.place(Clip(id: "a", file: "n1", start: 0, offset: 0, length: 4_800), on: "t1")
        let flac = StemOptions(format: .flac(.bits24), layout: .mono, rate: .session)
        let result = try Self.stems(package, range: 0..<4_800, options: flac)
        let name = try #require(result.files.first?.name)
        #expect(name.utf8.count == exportNameLimit && name.hasSuffix(".flac"))
        #expect(try readAudio(package.folder.url.appending(path: "stems/\(name)")).samples.count == 4_800)
    }

    /// C15: the mix pass runs only when the stem peaks sum over 1.0; at exactly 1.0 the mix cannot
    /// clip.
    @Test func theMixPeakIsMeasuredOnlyOverASumOfOne() {
        #expect(!needsMixPeak(stemPeaks: [0.5, 0.5]))
        #expect(needsMixPeak(stemPeaks: [0.5, 0.5 + Float(1).ulp]))
    }
}
