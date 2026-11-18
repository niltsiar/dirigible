import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Criterion C15 of decision 0076: a sync at the span cap fits its time budget and 512 MiB of
/// peak footprint in an optimized build (`make bench FILTER=SyncLagBenchmark`). A debug build
/// only prints the time.
struct SyncLagBenchmark {
    /// Writes `seconds` of seeded white noise at half scale as a 16-bit mono WAV at 48 kHz, one
    /// second at a time, so the fixture adds no footprint of its own.
    static func writeNoise(_ url: URL, seed: UInt64, seconds: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for second in 0..<seconds {
            let samples = buffer.floatChannelData![0]
            for index in 0..<48_000 { samples[index] = 0.5 * SpeechLike.noise(seed, second * 48_000 + index) }
            try file.write(from: buffer)
        }
    }

    /// The reference track holds 3 files of 1 h of noise, each with its own seed, so no passage
    /// repeats over 3 h. The clip is the second file at 3500 s, 100 s before its audio, and
    /// `within` 2364 s gives a cut span of 8328 s with no cut, so n = 2^24. The budget is 2 times
    /// the first optimized time (3.57 s on the Intel Mac), rounded up to 0.5 s.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aSpanAtTheCapFitsTheBudget() throws {
        let package = try MixPackage()
        let hour = 3600 * 48_000
        try package.session.addTrack("ref", name: "ref", layout: .mono)
        for index in 0..<3 {
            let id = FileID("n\(index)")
            try Self.writeNoise(
                package.url.appending(path: "\(clipsFolderName)/n\(index).wav"), seed: UInt64(41 + index), seconds: 3600
            )
            try package.session.addFile(AudioFile(id: id, path: "n\(index).wav", layout: .mono, length: Frames(hour)))
            try package.session.place(
                Clip(id: ClipID("N\(index)"), file: id, start: Frames(index * hour), offset: 0, length: Frames(hour)),
                on: "ref")
        }
        try package.session.addTrack("c", name: "c", layout: .mono)
        try package.session.place(
            Clip(id: "C", file: "n1", start: 168_000_000, offset: 0, length: Frames(hour)), on: "c")
        let span = try package.session.syncSpan("C", to: "ref", within: Frames(2364 * 48_000))
        #expect(span == 54_528_000..<454_272_000, "the span is 8328 s with no cut")

        let clock = ContinuousClock()
        let start = clock.now
        let result = try syncLag(of: "C", to: "ref", in: package.session, package: package.url, span: span)
        let elapsed = clock.now - start
        let footprint = peakFootprint()

        print(
            "bench report: sync of a 1 h clip in a span of 8328 s took \(elapsed), peak footprint \(footprint >> 20) MiB"
        )
        #expect(result.lag == 4_800_000, "\(result)")
        #expect(footprint <= 512 << 20, "peak footprint \(footprint >> 20) MiB")
        expectWithinBudget(elapsed, .seconds(7.5), "sync at the cap took \(elapsed)")
    }
}
