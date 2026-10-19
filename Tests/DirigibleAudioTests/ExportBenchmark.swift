import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Export run criterion 33: a 2 h session of 8 tracks (8 clips of one 2 h mono WAV) exports to
/// AAC 128 kbit/s stereo, and MP3 run criterion 15 to MP3 128 kbit/s stereo, each in 120 s or less, optimized build (`make bench FILTER=ExportBenchmark`).
/// A debug build exports 10 min with no budget: a smoke run, not the criterion.
struct ExportBenchmark {
    /// A package with 8 tracks of one mono WAV of `blocks` x 10 s: a 375 Hz sine at -20 dBFS. With
    /// `peaky`, each track is an eighth of the "train" of `SearchedExportTests`: a 1 kHz carrier and a
    /// 2 ms fs/4 burst every 250 ms from 0.5 s, so the mix limits hard at the podcast target. Each
    /// clip has `envelope`.
    static func eightTracks(
        blocks: Int, peaky: Bool = false, envelope: (Frames) throws -> GainEnvelope = { _ in .empty }
    )
        throws -> (package: MixPackage, frames: Frames)
    {
        let package = try MixPackage()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000))
        block.frameLength = 480_000
        var tone = sine(seconds: 10, rate: 48_000, frequency: peaky ? 1000 : 375).map { $0 / (peaky ? 40 : 5) }
        if peaky {
            for start in stride(from: 24_000, to: tone.count - 96, by: 12_000) {
                for index in 0..<96 { tone[start + index] += Float(sin(.pi / 2 * Double(index) + .pi / 4)) / 8 }
            }
        }
        block.floatChannelData![0].update(from: tone, count: tone.count)
        let writer = try ClipWriter(
            url: package.url.appending(path: "\(clipsFolderName)/long.wav"), file: "long.wav", format: format)
        for _ in 0..<blocks { try writer.write(block) }
        try writer.close()
        let frames = Frames(blocks * 480_000)
        try package.session.addFile(AudioFile(id: "f1", path: "long.wav", layout: .mono, length: frames))
        for track in 1...8 {
            try package.addTrack(
                TrackID("t\(track)"), clip: ClipID("c\(track)"), file: "f1", start: 0, offset: 0,
                length: frames, envelope: envelope(frames))
        }
        return (package, frames)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aTwoHourEightTrackExportFitsTheBudget() throws {
        try Self.exportTwoHours(.aac(.k128), to: "mix.m4a")
    }

    /// Gain envelope C8 (decision 0060): the AAC export of the same session with 400 envelope points
    /// on each clip, in 120 s or less.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aTwoHourEightTrackExportWithEnvelopesFitsTheBudget() throws {
        try Self.exportTwoHours(.aac(.k128), to: "mix.m4a", points: 400)
    }

    /// MP3 run criterion 15: the same session to MP3 128 kbit/s stereo through LAME, in 120 s or
    /// less. SwiftPM release builds LAME at -O2; the app build (-Os) is a manual check.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aTwoHourEightTrackMP3ExportFitsTheBudget() throws {
        try Self.exportTwoHours(.mp3(.k128), to: "mix.mp3")
    }

    /// Export-loudness criterion C12 (c): AAC 128 with the podcast target, the sine fixture (no
    /// limiting, no trial pass), with one read-back in 147 s or less: 1.4 times its first run of
    /// 105 s.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func anAACPodcastExportOfTheSineFixtureFitsTheBudget() throws {
        let passes = try LoudnessExportBenchmark.exportTwoHours(
            .aac(.k128), to: "mix.m4a", peaky: false, budget: .seconds(147))

        #expect((passes.trials, passes.writes, passes.readBacks) == (0, 1, 1), "\(passes)")
    }

    /// Export-loudness criterion C12 (d): AAC 128 with the podcast target, the "train" fixture
    /// (trial passes before the encode): 240 s or less with one encode, 420 s or less with two. A
    /// third encode fails.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func anAACPodcastExportOfTheTrainFixtureFitsTheBudget() throws {
        let passes = try LoudnessExportBenchmark.exportTwoHours(
            .aac(.k128), to: "mix.m4a", peaky: true, budget: .seconds(240), retryBudget: .seconds(420))

        #expect(passes.writes <= 2, "\(passes.writes) encodes")
    }

    /// Exports the 8 tracks to `format` stereo and expects the exact length and the budget. With
    /// `points`, each clip has that many envelope points from 0 dB to -18 dB, spread over the file,
    /// and the mix at the second point is 10^(g/20) times the mix with no envelope.
    static func exportTwoHours(_ format: ExportFormat, to name: String, points: Int = 0) throws {
        #if DEBUG
            let blocks = 60
        #else
            let blocks = 720
        #endif
        func gain(_ index: Int) -> Double { -1.5 * Double(index % 13) }
        let (package, frames) = try eightTracks(blocks: blocks) { frames in
            try #require(
                GainEnvelope(
                    (0..<points).map {
                        GainEnvelope.Point(frame: Frames(frames.count * $0 / (points - 1)), gain: Gain(dB: gain($0))!)
                    }))
        }
        if points > 1 {
            // The 8 tracks play the tone of `eightTracks` at the file frame of the second point.
            let second = Frames(frames.count / (points - 1))
            let tone = Double(sine(seconds: 10, rate: 48_000, frequency: 375)[second.count % 480_000] / 5)
            let mix = Double(try package.mix(second..<second + Frames(1))[0][0])
            #expect(abs(mix / (8 * tone) - pow(10, gain(1) / 20)) <= 1e-5, "the mix reads the envelope: \(mix)")
        }
        let out = package.folder.url.appending(path: name)

        let clock = ContinuousClock()
        let start = clock.now
        let faults = try exportMix(
            package.session, source: #require(ExportSource(range: 0..<frames)),
            options: ExportOptions(format: format, layout: .stereo, rate: .session), to: out,
            package: { package.url }
        ).faults
        let elapsed = clock.now - start

        print("ExportBenchmark: \(blocks * 10) s of 8 tracks to \(name) in \(elapsed)")
        #expect(faults == [:])
        #expect(try AVAudioFile(forReading: out).length == AVAudioFramePosition(frames.count))
        #if !DEBUG
            #expect(elapsed <= .seconds(120), "the export took \(elapsed)")
        #endif
    }
}
