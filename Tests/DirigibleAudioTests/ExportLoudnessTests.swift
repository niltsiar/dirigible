import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Run 9a criterion 5: the presets of decision 0008.
struct LoudnessTargetTests {
    @Test func presetsFollowTheLayout() {
        let stereo = LoudnessTarget.allCases.map { $0.integrated(for: .stereo).value }
        let mono = LoudnessTarget.allCases.map { $0.integrated(for: .mono).value }
        #expect(LoudnessTarget.allCases == [.podcast, .speech, .ebu, .atsc])
        #expect(stereo == [-16, -18, -23, -24], "stereo: \(stereo)")
        #expect(mono == [-19, -21, -26, -27], "mono: \(mono)")
    }
}

/// Run 9a criteria 6 to 11, 16, and 17: `exportMix` with a loudness target. The read-back is the
/// export file read as Float.
struct ExportLoudnessTests {
    /// A 1 kHz carrier at -20 dBFS with a 1 ms burst of an fs/4 sine at 1.0 FFS, 45 degrees, at
    /// 5, 10, and 15 s (criterion 8). Probe C8 reads I = -19.85 LUFS.
    static func bursts() -> [[Float]] {
        var samples = tone([(20, -20)])[0]
        for second in [5, 10, 15] {
            for index in 0..<48 { samples[second * 48_000 + index] += Float(sin(.pi / 2 * Double(index) + .pi / 4)) }
        }
        return [samples, samples]
    }

    static func export(
        _ channels: [[Float]], _ options: ExportOptions, to name: String = "mix.wav", chunk: Int = 48_000,
        progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }
    ) throws -> (url: URL, result: ExportResult, package: MixPackage) {
        let package = try ExportTests.package(channels)
        let url = package.folder.url.appending(path: name)
        let source = try #require(ExportSource(range: 0..<Frames(channels[0].count)))
        let result = try exportMix(
            package.session, source: source, options: options, to: url, package: { package.url }, progress: progress,
            isCancelled: isCancelled, chunk: chunk)
        return (url, result, package)
    }

    static func options(_ loudness: LoudnessTarget?, _ layout: ChannelLayout = .stereo, bits: BitDepth = .bits24)
        -> ExportOptions
    { ExportOptions(format: .wav(bits), layout: layout, rate: .session, loudness: loudness) }

    static func expectGain(
        _ report: LoudnessReport?, _ expected: Double, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let gain = report?.gain.dB ?? .nan
        #expect(abs(gain - expected) <= 0.05, "the gain: \(gain) dB, not \(expected)", sourceLocation: sourceLocation)
    }

    /// I = -30.0 LUFS, so the gain is +14.0 dB.
    @Test func aQuietMixReachesTheTarget() throws {
        let export = try Self.export(tone([(20, -30)]), Self.options(.podcast))

        let report = try #require(export.result.loudness)
        expectLUFS(report.target, -16, tolerance: 0, "the target")
        expectLUFS(report.measured, -30, "the measured loudness")
        Self.expectGain(report, 14)
        expectLUFS(report.output, -16, "the output loudness")
        expectDBTP(report.truePeak, -16, above: 0.1, below: 0.1, "the report true peak")
        let back = try ExportTests.read(export.url).channels
        expectLUFS(try measure(back).integrated, -16, "the read-back")
        expectDBTP(try truePeak(back), -16, above: 0.1, below: 0.1, "the read-back true peak")
    }

    /// The fold is 0.5 x L: -34 dBFS, I = -37.0 LUFS. The mono target is -19, so the gain is +18.
    @Test func aMonoExportMeasuresTheFold() throws {
        let left = tone([(20, -28)])[0]
        let export = try Self.export([left, [Float](repeating: 0, count: left.count)], Self.options(.podcast, .mono))

        let report = try #require(export.result.loudness)
        expectLUFS(report.measured, -37, "the measured fold")
        Self.expectGain(report, 18)
        let back = try ExportTests.read(export.url).channels
        #expect(back.count == 1)
        expectLUFS(try measure(back).integrated, -19, "the mono read-back")
    }

    /// The first gain is +3.85 dB, so the bursts reach about +3.9 dBTP; the limiter takes them to
    /// the ceiling and no lower than -1.3 dBTP. It loses 0.13 LU, so the search raises the gain to
    /// +3.99 dB (probe P5).
    @Test func theLimiterHoldsTheCeiling() throws {
        let export = try Self.export(Self.bursts(), Self.options(.podcast))

        let report = try #require(export.result.loudness)
        expectLUFS(report.measured, -19.85, "the measured bursts")
        Self.expectGain(report, 3.99)
        expectDBTP(try truePeak(ExportTests.read(export.url).channels), -1, above: 0, below: 0.3, "the read-back peak")
        expectDBTP(report.truePeak, -1, above: 0, below: 0.3, "the report true peak")
        expectLUFS(report.output, -16, "the output loudness")
    }

    /// With no limiting, each sample is the mix sample x the gain, at the same frame. The mix
    /// reads the clip from a 24-bit file, so it is the input.
    @Test func theLimiterIsTransparentUnderTheCeiling() throws {
        let export = try Self.export(tone([(20, -30)]), Self.options(.podcast))
        let input = try export.package.mix(0..<960_000)

        let gain = Float(pow(10, try #require(export.result.loudness).gain.dB / 20))
        let back = try ExportTests.read(export.url)
        #expect(back.length == 960_000, "the length: \(back.length)")
        for (out, source) in zip(back.channels, input) {
            #expect(
                maxError(out, source.map { $0 * gain }) <= 0x1p-22,
                "the gained mix differs: \(maxError(out, source.map { $0 * gain }))")
        }
    }

    /// 300 ms to 500 ms after each burst, the carrier has the level it had before the burst.
    @Test func theLimiterReleases() throws {
        let back = try ExportTests.read(Self.export(Self.bursts(), Self.options(.podcast)).url).channels[0]

        for second in [5, 10, 15] {
            let before = Array(back[(second * 48_000 - 24_000)..<(second * 48_000 - 14_400)])
            let end = second * 48_000 + 48
            let after = Array(back[(end + 14_400)..<(end + 24_000)])
            let loss = ExportTests.rmsDB(after) - ExportTests.rmsDB(before)
            #expect(abs(loss) <= 0.1, "\(second) s: the carrier after the burst is \(loss) dB off")
        }
    }

    /// Silence and a mix of 300 ms have no gated block: the gain is 0 dB, no trial pass runs, and one
    /// file is written. The WAV equals the export with no target. An AAC or MP3 file is read back,
    /// and a nil true peak counts as under the ceiling, so it gets no retry.
    @Test(
        arguments: [[(20.0, -Double.infinity)], [(0.3, -23.0)]], [ExportFormat.wav(.bits24), .aac(.k128), .mp3(.k128)])
    func noMeasurementMeansNoGain(parts: [(Double, Double)], format: ExportFormat) throws {
        let channels = tone(parts.map { (seconds: $0.0, dBFS: $0.1) })
        let options = ExportOptions(format: format, layout: .stereo, rate: .session, loudness: .podcast)
        let target = try SearchedExportTests.export(channels, options, to: "target.out")

        let report = try #require(target.result.loudness)
        #expect(report.measured == nil && report.gain == .zero, "measured \(String(describing: report.measured))")
        #expect(target.trials == 0 && target.writes == 1, "\(target.steps)")
        guard case .wav = format else { return }
        let plain = try Self.export(
            channels, ExportOptions(format: format, layout: .stereo, rate: .session), to: "plain.wav")
        #expect(plain.result.loudness == nil)
        let same = try Data(contentsOf: target.url) == Data(contentsOf: plain.url)
        #expect(same, "the file with a target differs from the file with no target")
    }

    /// Pass 1 maps to 0...0.15 and the write to 0.15...1 when no trial pass runs, with one percent
    /// counter.
    @Test func progressSpansBothPasses() throws {
        var values: [Double] = []
        _ = try Self.export(tone([(20, -30)]), Self.options(.podcast), chunk: 4_800, progress: { values.append($0) })

        #expect(values.count <= 101, "\(values.count) calls")
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "the values go down")
        #expect(values.last == 1, "the last value: \(String(describing: values.last))")
        #expect(values.contains(0.15), "no value at the end of pass 1")
    }

    /// The cancel at the third chunk of pass 1 leaves no file, and pass 2 does not start.
    @Test func aCancelInTheMeasurePassLeavesNothing() throws {
        var (checks, values) = (0, [Double]())
        let package = try ExportTests.package(tone([(20, -30)]))
        let url = package.folder.url.appending(path: "mix.wav")
        let source = try #require(ExportSource(range: 0..<960_000))

        #expect(throws: ExportError.cancelled) {
            try exportMix(
                package.session, source: source, options: Self.options(.podcast), to: url, package: { package.url },
                progress: { values.append($0) },
                isCancelled: {
                    checks += 1
                    return checks == 3
                })
        }

        #expect((values.max() ?? 0) <= 0.1, "pass 2 ran: progress \(values)")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: package.folder.url.path)
        #expect(!names.contains { $0.hasSuffix(".tmp") }, "left: \(names)")
    }

    /// Code gate 1: a gain over the 20 dB auto-level limit is marked, so the window can show it
    /// as a warning. A -60 LUFS selection gets +44 dB; a -30 LUFS one gets +14 dB.
    /// A slow test: 5.1 s alone in a debug build, over the 5 s of a fast test.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aLargeGainIsMarked() throws {
        let quiet = try #require(try Self.export(tone([(20, -60)]), Self.options(.podcast)).result.loudness)
        let plain = try #require(try Self.export(tone([(20, -30)]), Self.options(.podcast)).result.loudness)

        #expect(quiet.exceedsLevelLimit, "gain \(quiet.gain.dB) dB is not marked")
        #expect(!plain.exceedsLevelLimit, "gain \(plain.gain.dB) dB is marked")
    }

    /// The boundary of the limit (run 11b-1, control c2): a gain of exactly 20.0 dB is inside it
    /// (the info banner), and 20.1 dB or -20.1 dB is over it (the warning).
    @Test func theLimitItselfIsNotOverTheLimit() throws {
        func report(_ dB: Double) throws -> LoudnessReport {
            LoudnessReport(
                target: LUFS(value: -16), measured: LUFS(value: -16 - dB), gain: try #require(Gain(dB: dB)),
                output: LUFS(value: -16), truePeak: -1)
        }

        #expect(try !report(20).exceedsLevelLimit, "20.0 dB is marked")
        #expect(try !report(-20).exceedsLevelLimit, "-20.0 dB is marked")
        #expect(try report(20.1).exceedsLevelLimit, "20.1 dB is not marked")
        #expect(try report(-20.1).exceedsLevelLimit, "-20.1 dB is not marked")
    }

    /// A constant 0.25 LSB of 16 bit, 1 s, stereo.
    static let quarterLSB = [[Float]](repeating: [Float](repeating: 0.25 / 32_768, count: 48_000), count: 2)

    /// TPDF dither keeps a level under 1 LSB: the mean of the integers is 0.25 LSB. With no
    /// dither the converter rounds each sample to 0 (probe D1).
    @Test func aWAV16HasTPDFDither() throws {
        let back = try ExportTests.read(Self.export(Self.quarterLSB, Self.options(nil, bits: .bits16)).url)

        for channel in back.channels {
            let integers = channel.map { Int(($0 * 32_768).rounded()) }
            let mean = Double(integers.reduce(0, +)) / Double(integers.count)
            #expect(abs(mean - 0.25) <= 0.02, "the mean: \(mean) LSB, not 0.25")
            #expect(Set(integers).isSubset(of: [-1, 0, 1]), "values: \(Set(integers).sorted())")
        }
    }

    /// The seed is fixed, so two exports are equal. A 24-bit export has no dither.
    @Test func ditherIsRepeatableAndOnlyFor16Bit() throws {
        // Each export keeps its package, so its folder stays until the end.
        let first = try Self.export(Self.quarterLSB, Self.options(nil, bits: .bits16), to: "a.wav")
        let second = try Self.export(Self.quarterLSB, Self.options(nil, bits: .bits16), to: "b.wav")
        let deep = try ExportTests.read(Self.export(Self.quarterLSB, Self.options(nil), to: "c.wav").url)

        let same = try Data(contentsOf: first.url) == Data(contentsOf: second.url)
        #expect(same, "two 16-bit exports differ")
        let values = Set(deep.channels.joined().map { Int(($0 * 8_388_608).rounded()) })
        #expect(values == [64], "the 24-bit values: \(values.sorted())")
    }

    /// Mute and solo C6: the loudness pass meters the heard mix. t1 at -20 dBFS is muted, so
    /// the pass measures t2 at -30 dBFS alone (both together measure about -17.6 LUFS).
    @Test func theLoudnessPassMetersOnlyTheAudibleTracks() throws {
        let package = try ExportTests.package(tone([(20, -20)]))
        let quiet = tone([(20, -30)])
        try package.addFile("f2", channels: quiet)
        try package.addTrack("t2", layout: .stereo, clip: "c2", file: "f2", start: 0, offset: 0, length: 960_000)
        try package.session.setMuted(true, tracks: ["t1"])

        let url = package.folder.url.appending(path: "mix.wav")
        let source = try #require(ExportSource(range: 0..<960_000))
        let result = try exportMix(
            package.session, source: source, options: Self.options(.podcast), to: url, package: { package.url })

        expectLUFS(result.loudness?.measured, -30, "the measured loudness is t2 alone")
    }
}
