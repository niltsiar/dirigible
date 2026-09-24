import AVFoundation
import AudioToolbox
import Foundation
import Testing

@testable import DirigibleAudio

/// The clip writer is RF64: a plain RIFF WAV under 4 GiB, RF64 over it (criterion 22).
struct ClipWriterTests {
    let folder: TemporaryFolder

    init() throws { folder = try TemporaryFolder() }

    func write(frames: Int, channels: Int, to url: URL) throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(channels)))
        let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 20))
        let writer = try ClipWriter(url: url, file: "Clips/clip.wav", format: format)
        var written = 0
        while written < frames {
            block.frameLength = AVAudioFrameCount(min(1 << 20, frames - written))
            try writer.write(block)
            written += Int(block.frameLength)
        }
        try writer.close()
    }

    @Test func aSmallClipIsAPlainRIFFWAV() throws {
        #expect(ClipWriter.fileType == kAudioFileRF64Type)
        let url = folder.url.appending(path: "clip.wav")

        try write(frames: 48_000, channels: 1, to: url)

        let bytes = try Data(contentsOf: url)
        #expect(bytes.prefix(4) == Data("RIFF".utf8))
        #expect(bytes[12..<16] == Data("JUNK".utf8))
        #expect(bytes[16..<20] == Data([28, 0, 0, 0]))
        #expect(try AVAudioFile(forReading: url).length == 48_000)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aClipOver4GiBIsRF64() throws {
        let url = folder.url.appending(path: "clip.wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try write(frames: 716_000_000, channels: 2, to: url)

        let handle = try FileHandle(forReadingFrom: url)
        let magic = try handle.read(upToCount: 4)
        try handle.close()
        #expect(magic == Data("RF64".utf8))
        #expect(try AVAudioFile(forReading: url).length == 716_000_000)
    }
}
