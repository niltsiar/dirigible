import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Export run criterion 33: a 2 h session of 8 tracks (8 clips of one 2 h mono WAV) exports to
/// AAC 128 kbit/s stereo, and MP3 run criterion 15 to MP3 128 kbit/s stereo, each in 120 s or less, optimized build (`make bench FILTER=ExportBenchmark`).
/// A debug build exports 10 min with no budget: a smoke run, not the criterion.
struct ExportBenchmark {
    /// A package with 8 tracks of one mono WAV of `blocks` x 10 s: a 375 Hz sine at -20 dBFS.
    static func eightTracks(blocks: Int) throws -> (package: MixPackage, frames: Frames) {
        let package = try MixPackage()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000))
        block.frameLength = 480_000
        let tone = sine(seconds: 10, rate: 48_000, frequency: 375).map { $0 / 5 }
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
                length: frames)
        }
        return (package, frames)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aTwoHourEightTrackExportFitsTheBudget() throws {
        try Self.exportTwoHours(.aac(.k128), to: "mix.m4a")
    }

    /// MP3 run criterion 15: the same session to MP3 128 kbit/s stereo through LAME, in 120 s or
    /// less. SwiftPM release builds LAME at -O2; the app build (-Os) is a manual check.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aTwoHourEightTrackMP3ExportFitsTheBudget() throws {
        try Self.exportTwoHours(.mp3(.k128), to: "mix.mp3")
    }

    /// Exports the 8 tracks to `format` stereo and expects the exact length and the budget.
    static func exportTwoHours(_ format: ExportFormat, to name: String) throws {
        #if DEBUG
            let blocks = 60
        #else
            let blocks = 720
        #endif
        let (package, frames) = try eightTracks(blocks: blocks)
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
