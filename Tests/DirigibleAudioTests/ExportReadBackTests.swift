import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Run export-loudness: `exportMix` reads back each AAC and MP3 file, decoded as macOS decodes it,
/// and the report is the file. "Train" is `SearchedExportTests.train`; "tone" is a 20 s sine at
/// -30 dBFS, which the limiter does not change.
struct ReadBackExportTests {
    static func options(_ format: ExportFormat, _ layout: ChannelLayout = .stereo) -> ExportOptions {
        ExportOptions(format: format, layout: layout, rate: .session, loudness: .podcast)
    }

    /// The loudness and the true peak of the file as our meters read the decode.
    static func decoded(_ url: URL) throws -> (loudness: Double, truePeak: Double) {
        let file = try ExportTests.read(url)
        let loudness = try #require(try measure(file.channels, rate: Int(file.rate)).integrated).value
        return (loudness, try #require(try truePeak(file.channels)))
    }

    /// The setup of the retry: AAC 128 and "train" with a start margin of 0 dB, so that the first
    /// file decodes over the ceiling.
    static func overshoot(
        limits: LoudnessSearch.Limits = .init(), chunk: Int = 48_000, to name: String = "mix.m4a",
        progress: (Double) -> Void = { _ in }
    ) throws -> SearchedExportTests.Run {
        try SearchedExportTests.export(
            SearchedExportTests.train(), options(.aac(.k128)), to: name,
            tuning: ExportTuning(limits: limits, startMargin: 0), chunk: chunk, progress: progress)
    }

    static func expectReport(
        _ export: SearchedExportTests.Run, equals decoded: (loudness: Double, truePeak: Double),
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let report = try #require(export.result.loudness, sourceLocation: sourceLocation)
        expectLUFS(
            report.output, decoded.loudness, tolerance: 0.05, "the report output", sourceLocation: sourceLocation)
        let peak = report.truePeak ?? .nan
        #expect(
            abs(peak - decoded.truePeak) <= 0.05, "the report true peak \(peak), the file \(decoded.truePeak)",
            sourceLocation: sourceLocation)
    }

    @Test func anAACExportDecodesUnderTheCeiling() throws {
        let export = try SearchedExportTests.export(
            SearchedExportTests.train(), Self.options(.aac(.k128)), to: "mix.m4a")

        let decoded = try Self.decoded(export.url)

        #expect(decoded.truePeak <= -1.0, "the decoded true peak: \(decoded.truePeak) dBTP")
        try Self.expectReport(export, equals: decoded)
    }

    /// The converter changes a WAV, FLAC, or float CAF file at 44.1 kHz from a 48 kHz session, so
    /// the file is read back and the report is the file.
    @Test(arguments: [
        (ExportFormat.wav(.bits24), "mix.wav"), (.flac(.bits24), "mix.flac"), (.floatCAF, "mix.caf"),
    ])
    func aLosslessExportAtAnotherRateReadsBack(format: ExportFormat, name: String) throws {
        let options = ExportOptions(format: format, layout: .stereo, rate: .hz44100, loudness: .podcast)
        let export = try SearchedExportTests.export(SearchedExportTests.train(seconds: 5), options, to: name)

        let decoded = try Self.decoded(export.url)

        #expect(export.readBacks == 1, "\(export.readBacks) read-backs")
        try Self.expectReport(export, equals: decoded)
    }

    @Test func anAACExportDecodesAtTheTarget() throws {
        let export = try SearchedExportTests.export(
            SearchedExportTests.train(), Self.options(.aac(.k128)), to: "mix.m4a")

        let decoded = try Self.decoded(export.url)

        #expect(abs(decoded.loudness - -16) <= 0.2, "the decoded loudness: \(decoded.loudness) LUFS")
    }

    /// The first file decodes over -1.0 dBTP, so a second file with a lower ceiling follows.
    @Test func aLossyOvershootGetsAnotherEncode() throws {
        let export = try Self.overshoot()

        let decoded = try Self.decoded(export.url)

        #expect(export.writes == 2, "\(export.writes) writes")
        #expect(decoded.truePeak <= -1.0, "the decoded true peak: \(decoded.truePeak) dBTP")
        try Self.expectReport(export, equals: decoded)
    }

    /// The first step has the gain `target + offset - measured` and the start ceiling of the format:
    /// a write for the tone, a trial pass for the train. Then one write is enough.
    @Test(arguments: [
        (ExportFormat.aac(.k128), true, 0.0, -2.5), (.mp3(.k128), true, 0.45, -1.5),
        (.aac(.k128), false, 0.0, -2.5), (.mp3(.k128), false, 0.45, -1.5), (.mp3(.k256), false, 0.0, -1.5),
    ])
    func aLossyExportEncodesOnceWithNoRetry(
        format: ExportFormat, peaky: Bool, offset: Double, startCeiling: Double
    ) throws {
        let export = try SearchedExportTests.export(
            peaky ? SearchedExportTests.train() : tone([(20, -30)]), Self.options(format), to: "mix.out")

        let measured = try #require(export.result.loudness?.measured).value
        let (isTrial, gain, ceiling): (Bool, Double, Double) =
            switch try #require(export.steps.first) {
            case .trial(let gain, let ceiling): (true, gain, ceiling)
            case .write(let gain, let ceiling): (false, gain, ceiling)
            case .readBack, .done: (false, .nan, .nan)
            }
        #expect(isTrial == peaky, "the first step is a \(isTrial ? "trial pass" : "write")")
        #expect(abs(gain - (-16 + offset - measured)) <= 1e-6, "the first gain: \(gain) dB")
        #expect(abs(ceiling - startCeiling) <= 1e-9, "the first ceiling: \(ceiling) dBTP")
        #expect(export.writes == 1, "\(export.writes) writes")
    }

    @Test(arguments: [false, true])
    func anMP3ExportDecodesAtTheTarget(peaky: Bool) throws {
        let export = try SearchedExportTests.export(
            peaky ? SearchedExportTests.train() : tone([(20, -30)]), Self.options(.mp3(.k128)), to: "mix.mp3")

        let decoded = try Self.decoded(export.url)

        #expect(abs(decoded.loudness - -16) <= 0.2, "the decoded loudness: \(decoded.loudness) LUFS")
        #expect(decoded.truePeak <= -1.0, "the decoded true peak: \(decoded.truePeak) dBTP")
        try Self.expectReport(export, equals: decoded)
    }

    /// The retry round writes the same temporary file again: two exports decode to equal samples,
    /// and two WAV 16 exports give equal bytes.
    @Test func aRetriedExportIsRepeatable() throws {
        let first = try Self.overshoot(to: "a.m4a")
        let second = try Self.overshoot(to: "b.m4a")

        #expect(first.writes == 2 && second.writes == 2, "\(first.writes) and \(second.writes) writes")
        let same = try ExportTests.read(first.url).channels == ExportTests.read(second.url).channels
        #expect(same, "two AAC exports decode to other samples")
        let options = ExportLoudnessTests.options(.podcast, bits: .bits16)
        let wavs = try [
            SearchedExportTests.export(SearchedExportTests.train(), options),
            SearchedExportTests.export(SearchedExportTests.train(), options),
        ].map { try Data(contentsOf: $0.url) }
        #expect(wavs[0] == wavs[1], "two WAV 16 exports differ")
    }

    @Test func progressNeverGoesDownAcrossARetry() throws {
        var values: [Double] = []

        let export = try Self.overshoot(chunk: 4_800) { values.append($0) }

        #expect(export.writes == 2, "\(export.writes) writes")
        #expect(values.count <= 101, "\(values.count) calls")
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "the values go down")
        #expect(values.last == 1, "the last value: \(String(describing: values.last))")
        #expect(values.contains { 0.75 < $0 && $0 <= 0.75 + 0.25 / 3 }, "no value in the read-back band")
        #expect(values.contains { 0.75 + 0.25 / 3 < $0 && $0 < 1 }, "no value in a retry round")
    }

    /// The first write takes 0.3...0.75 of the bar. The read-back and the two retry rounds share
    /// 0.75...1 in three equal bands, and inside a retry round the trial passes, the write, and the
    /// read-back follow each other with no gap.
    @Test func theProgressBandsGiveEachRoundItsOwnShare() {
        let bands = ProgressBands(readsBack: true, limits: .init())
        let third = 0.25 / 3
        func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-9 }

        #expect(bands.write(round: 0, afterTrials: true) == 0.3...0.75)
        #expect(bands.write(round: 0, afterTrials: false) == 0.15...0.75)
        #expect(bands.trial(round: 0, index: 3).upperBound == 0.3)
        #expect(bands.readBack(round: 0).lowerBound == 0.75)
        #expect(same(bands.readBack(round: 0).upperBound, 0.75 + third), "\(bands.readBack(round: 0))")
        for round in 1...2 {
            let low = 0.75 + third * Double(round)
            #expect(same(bands.trial(round: round, index: 0).lowerBound, low), "round \(round)")
            #expect(
                same(
                    bands.trial(round: round, index: 3).upperBound,
                    bands.write(round: round, afterTrials: true).lowerBound))
            #expect(
                same(bands.write(round: round, afterTrials: true).upperBound, bands.readBack(round: round).lowerBound))
            #expect(same(bands.write(round: round, afterTrials: false).lowerBound, low), "round \(round)")
            #expect(same(bands.readBack(round: round).upperBound, low + third), "round \(round)")
        }
        #expect(ProgressBands(readsBack: false, limits: .init()).write(round: 0, afterTrials: true) == 0.3...1)
        #expect(ProgressBands(readsBack: true, limits: .init(retryRounds: 0)).readBack(round: 0) == 0.75...1)
    }

    /// The write is done and the read-back starts: the next cancel check is its first chunk.
    @Test func aCancelInTheReadBackLeavesNothing() throws {
        var (cancel, steps) = (false, [LoudnessSearch.Step]())
        let package = try ExportTests.package(tone([(20, -30)]))
        let source = try #require(ExportSource(range: 0..<960_000))
        var tuning = ExportTuning()
        tuning.afterWrite = { _ in cancel = true }
        tuning.onStep = { steps.append($0) }

        #expect(throws: ExportError.cancelled) {
            try exportMix(
                package.session, source: source, options: Self.options(.aac(.k128)),
                to: package.folder.url.appending(path: "mix.m4a"), package: { package.url }, isCancelled: { cancel },
                tuning: tuning)
        }

        #expect(steps.last == .readBack, "the cancel was not in the read-back: \(steps)")
        try MP3ExportTests.expectNoOutput(package)
    }

    /// The report is the last file, also when a cap stops the search: 1 trial pass, 1 write, and no
    /// retry for an overshoot.
    @Test func aCappedExportReportsItsLastFile() throws {
        let export = try Self.overshoot(limits: .init(trialPasses: 1, retryRounds: 0))

        let decoded = try Self.decoded(export.url)

        #expect(export.trials == 1 && export.writes == 1, "\(export.trials) trial passes, \(export.writes) writes")
        try Self.expectReport(export, equals: decoded)
    }

    /// A decode that ends before the written signal would report the values of a prefix, so the
    /// export fails with `.writeFailed` and leaves nothing.
    @Test func aReadBackThatEndsEarlyIsAWriteFault() throws {
        let package = try ExportTests.package(tone([(20, -30)]))
        let source = try #require(ExportSource(range: 0..<960_000))
        var tuning = ExportTuning()
        tuning.afterWrite = { url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            try? FileHandle(forWritingTo: url).truncate(atOffset: size / 2)
        }
        let options = ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .hz44100, loudness: .podcast)

        #expect {
            try exportMix(
                package.session, source: source, options: options,
                to: package.folder.url.appending(path: "mix.wav"), package: { package.url }, tuning: tuning)
        } throws: {
            if case ExportError.writeFailed = $0 { true } else { false }
        }

        try MP3ExportTests.expectNoOutput(package)
    }

    /// Core Audio fails on the padding after the last MP3 packet of some files at 44.1 kHz from a
    /// 48 kHz session (160 kbit/s, 1,000,003 frames): the decode has all the audio when it fails,
    /// so the export succeeds and the report has the values of the file.
    @Test func anMP3ExportKeepsItsReadBackWhenTheLastPacketDoesNotDecode() throws {
        let tone = ExportTests.tone(frames: 1_000_003, rms: -30)
        let options = ExportOptions(format: .mp3(.k160), layout: .stereo, rate: .hz44100, loudness: .podcast)

        let export = try SearchedExportTests.export([tone, tone], options, to: "mix.mp3")

        #expect(export.readBacks == 1, "\(export.readBacks) read-backs")
        let report = try #require(export.result.loudness)
        #expect(report.output != nil && report.truePeak != nil, "\(report)")
    }

    /// A file that Core Audio cannot open fails the export with `.writeFailed`, and leaves nothing.
    @Test func aReadBackFailureIsAWriteFault() throws {
        let package = try ExportTests.package(tone([(20, -30)]))
        let source = try #require(ExportSource(range: 0..<960_000))
        var tuning = ExportTuning()
        tuning.afterWrite = { try? Data(repeating: 7, count: 4_096).write(to: $0) }

        #expect {
            try exportMix(
                package.session, source: source, options: Self.options(.aac(.k128)),
                to: package.folder.url.appending(path: "mix.m4a"), package: { package.url }, tuning: tuning)
        } throws: {
            if case ExportError.writeFailed = $0 { true } else { false }
        }

        try MP3ExportTests.expectNoOutput(package)
    }
}
