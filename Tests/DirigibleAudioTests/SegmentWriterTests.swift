import AVFoundation
import Testing

@testable import DirigibleAudio

struct SegmentWriterTests {
    let folder: TemporaryFolder

    init() throws { folder = try TemporaryFolder() }

    func header(channels: Int) -> CaptureHeader {
        CaptureHeader(
            deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelCount: channels, latency: 48, firstSampleTime: 0, firstHostTimeNanos: 1_000)
    }

    /// Writes `samples` in blocks of 512 frames, and a checkpoint at the first block at or after
    /// each second.
    func write(_ samples: [Float], channels: Int, to writer: SegmentWriter) throws {
        let frames = samples.count / channels
        try samples.withUnsafeBufferPointer { all in
            for start in stride(from: 0, to: frames, by: 512) {
                let count = min(512, frames - start)
                if start % 48_000 < 512 {
                    try writer.checkpoint(
                        Checkpoint(
                            fileFrame: Int64(start), sampleTime: Double(start),
                            hostTimeNanos: 1_000 + UInt64(start) * 20_833))
                }
                let block = UnsafeBufferPointer(rebasing: all[(start * channels)..<((start + count) * channels)])
                try writer.write(block, frames: count)
            }
        }
    }

    /// The frames of the CAF as an `AVAudioFile` reads them, interleaved. It reads in blocks: one
    /// read of the whole length of an unclosed CAF gives fewer frames (probe 2026-09-24: 95232 of
    /// 96000), and reads in blocks give all of them.
    func read(_ url: URL) throws -> (rate: Double, samples: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let channels = Int(file.processingFormat.channelCount)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<Int(buffer.frameLength) {
                for channel in 0..<channels { samples.append(data[channel][frame]) }
            }
        }
        return (file.fileFormat.sampleRate, samples)
    }

    /// An open writer stands for a crashed process: synchronous writes are in the kernel, so
    /// another reader sees them, and the CAF data size is still "to the end of the file".
    @Test func anUnclosedWriterLeavesAReadableCAF() throws {
        let name = SegmentName(take: 1, arm: 1, segment: 1)
        let writer = try SegmentWriter(folder: folder.url, name: name, header: header(channels: 1))
        let samples = sine(seconds: 2, rate: 48_000)
        try write(samples, channels: 1, to: writer)

        let caf = folder.url.appending(path: "take1-1-1.caf")
        let open = try read(caf)
        #expect(open.rate == 48_000)
        #expect(open.samples.count == 96_000)
        #expect(open.samples == samples)
        let sidecar = try #require(Sidecar.decode(Data(contentsOf: folder.url.appending(path: "take1-1-1.sidecar"))))
        #expect(sidecar.header == header(channels: 1))
        #expect(sidecar.checkpoints.map(\.fileFrame) == [0, 48_128])

        try writer.close()
        #expect(try read(caf).samples == samples)
    }

    @Test func aStereoWriterKeepsTheChannelOrder() throws {
        let writer = try SegmentWriter(
            folder: folder.url, name: SegmentName(take: 2, arm: 1, segment: 1), header: header(channels: 2))
        let samples = sine(seconds: 0.5, rate: 48_000, channels: 2)
        try write(samples, channels: 2, to: writer)
        try writer.close()

        let back = try read(folder.url.appending(path: "take2-1-1.caf"))
        #expect(back.samples.count == 48_000)
        #expect(back.samples == samples)
    }

    @Test func aWriterInAFolderThatDoesNotExistThrows() {
        let missing = folder.url.appending(path: "missing")
        #expect(throws: CaptureError.self) {
            try SegmentWriter(
                folder: missing, name: SegmentName(take: 1, arm: 1, segment: 1), header: header(channels: 1))
        }
    }
}
