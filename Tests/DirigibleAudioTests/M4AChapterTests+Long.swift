import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Plan gate G6 and G13: the chapter copy of a 1 h AAC file with 500 chapters, each with a JPEG,
/// reads the cancel at least every 50 ms, from the call to the end of the copy.
extension M4AChapterTests {
    /// Writes `seconds` of a stereo tone at 44.1 kHz as AAC, through the export encoder.
    func longSource(seconds: Int) throws -> URL {
        let source = package.folder.url.appending(path: "long.m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        let tone = ExportTests.tone(frames: 44_100, rate: 44_100)
        for channel in 0..<2 { buffer.floatChannelData![channel].update(from: tone, count: tone.count) }
        try writeFile(source, format: .aac(.k128), rate: 44_100, client: format) { sink throws(ExportError) in
            for _ in 0..<seconds { try sink(buffer) }
        }
        return source
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func anHourCopyWith500ChaptersReadsTheCancelOften() throws {
        let source = try longSource(seconds: 3_600)
        let frames = try validFrames(source)
        let jpeg = try bytes(try artwork(300))
        let chapters = (0..<500).map { ExportChapter(title: "Chapter \($0)", start: $0 * 7 * 44_100, image: jpeg) }
        let output = package.folder.url.appending(path: "long-chapters.m4a")
        var (last, largest, reads, at) = (Date(), 0.0, 0, 0)
        let begin = last
        try tagM4A(
            source, episode: Episode(), artwork: nil, chapters: chapters, chapterArtwork: nil, rate: 44_100,
            frames: frames, to: output,
            isCancelled: {
                let now = Date()
                reads += 1
                if now.timeIntervalSince(last) > largest { (largest, at) = (now.timeIntervalSince(last), reads) }
                last = now
                return false
            })
        let total = Date().timeIntervalSince(begin)
        print(
            "G13 probe: 1 h copy with 500 JPEG chapters in \(total) s, largest gap between cancel reads \(largest) s, before read \(at) of \(reads)"
        )
        #expect(largest < 0.05, "largest gap \(largest) s")
        try FileManager.default.removeItem(at: output)

        let start = Date()
        #expect(throws: ExportError.cancelled) {
            try tagM4A(
                source, episode: Episode(), artwork: nil, chapters: chapters, chapterArtwork: nil, rate: 44_100,
                frames: frames, to: output, isCancelled: { Date().timeIntervalSince(start) > 0.5 })
        }
        let stopped = Date().timeIntervalSince(start)
        print("G13 probe: a cancel at 0.5 s returned after \(stopped) s")
        #expect(stopped < 0.6, "the cancel returned after \(stopped) s")
        #expect(!FileManager.default.fileExists(atPath: output.path), "the partial file stays")
    }
}
