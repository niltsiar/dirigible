import AVFoundation
import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Interleaved sine samples with amplitude 0.5. Channel `c` has the frequency
/// `frequency * (c + 1)`, so a test can tell the channels apart.
func sine(seconds: Double, rate: Double, channels: Int = 1, frequency: Double = 1000) -> [Float] {
    let frames = Int((seconds * rate).rounded())
    var samples = [Float](repeating: 0, count: frames * channels)
    for frame in 0..<frames {
        for channel in 0..<channels {
            let phase = 2 * Double.pi * frequency * Double(channel + 1) * Double(frame) / rate
            samples[frame * channels + channel] = Float(0.5 * sin(phase))
        }
    }
    return samples
}

/// A unique temporary folder, removed at deinit.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "DirigibleAudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// SplitMix64: a small seeded generator, so a random test gives the same values on each run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// The frames of an audio file as `AVAudioFile` reads them, interleaved. It reads in blocks: one
/// read of the whole length of an unclosed CAF gives fewer frames (probe 2026-09-24: 95232 of
/// 96000), and reads in blocks give all of them.
func readAudio(_ url: URL) throws -> (rate: Double, bits: Int?, samples: [Float]) {
    let file = try AVAudioFile(forReading: url)
    let channels = Int(file.processingFormat.channelCount)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
    var samples: [Float] = []
    samples.reserveCapacity(Int(file.length) * channels)
    while file.framePosition < file.length {
        try file.read(into: buffer)
        if buffer.frameLength == 0 { break }
        let data = try #require(buffer.floatChannelData)
        let frames = Int(buffer.frameLength)
        if channels == 1 {
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            continue
        }
        for frame in 0..<frames {
            for channel in 0..<channels { samples.append(data[channel][frame]) }
        }
    }
    return (file.fileFormat.sampleRate, file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, samples)
}

/// The host time of the take start in the take packages: 1000 s after boot.
let takeStart: UInt64 = 1_000_000_000_000

/// A package with tracks and a `<recording>` in `session.xml`, and segments made by the real
/// `SegmentWriter`. It is removed at deinit.
final class TakePackage {
    let folder: TemporaryFolder
    let url: URL
    var capture: URL { url.appending(path: "Capture") }

    init(
        sampleRate: Int = 48_000, tracks: [(TrackID, ChannelLayout)] = [("t1", .mono)], take: Int = 1,
        playhead: Frames = 96_000
    ) throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: sampleRate)
        for (id, layout) in tracks { try session.addTrack(id, name: id.rawValue, layout: layout) }
        try session.setRecording(
            Recording(
                take: take, playheadFrame: playhead, takeStartHostTimeNanos: takeStart,
                armedTracks: tracks.map(\.0)))
        try session.write(to: url)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
    }

    func read() throws -> Session { try Session(contentsOf: url) }

    static func header(
        rate: Double = 48_000, channels: Int = 1, latency: Int = 48, firstHost: UInt64 = takeStart + 10_000_000
    ) -> CaptureHeader {
        CaptureHeader(
            deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: rate, availableRates: [rate...rate],
            channelCount: channels, latency: latency, firstSampleTime: 512, firstHostTimeNanos: firstHost)
    }

    /// Checkpoints at frame 0, at each whole second, and at the last frame, on a clock that runs
    /// at `realRate` (default: the header rate).
    static func checkpoints(frames: Int, header: CaptureHeader, realRate: Double? = nil) -> [Checkpoint] {
        let rate = realRate ?? header.nominalRate
        let second = Int(rate.rounded())
        return (Array(stride(from: 0, to: frames, by: second)) + [frames - 1]).map { frame in
            Checkpoint(
                fileFrame: Int64(frame), sampleTime: header.firstSampleTime + Double(frame),
                hostTimeNanos: header.firstHostTimeNanos + UInt64((Double(frame) / rate * 1e9).rounded()))
        }
    }

    /// Writes one segment with the real writer. It closes the writer unless `open` is true; the
    /// caller then keeps the returned writer alive as a crashed process.
    @discardableResult
    func segment(
        take: Int = 1, arm: Int = 1, segment: Int = 1, header: CaptureHeader = TakePackage.header(), samples: [Float],
        checkpoints: [Checkpoint]? = nil, open: Bool = false
    ) throws -> SegmentWriter {
        let frames = samples.count / header.channelCount
        let writer = try SegmentWriter(
            folder: capture, name: SegmentName(take: take, arm: arm, segment: segment), header: header)
        for checkpoint in checkpoints ?? Self.checkpoints(frames: frames, header: header) {
            try writer.checkpoint(checkpoint)
        }
        try samples.withUnsafeBufferPointer { try writer.write($0, frames: frames) }
        if !open { try writer.close() }
        return writer
    }
}

/// Records of `frames` frames from interleaved samples. `buffers[i]` holds the samples of buffer
/// `i` with `layout[i]` channels. The host time runs at `rate` from `hostStart`.
func records(
    _ buffers: [[Float]], layout: [Int], rate: Double, frames: Int = 512, sampleStart: Double = 0,
    hostStart: UInt64 = takeStart
) -> [InputRecord] {
    let total = buffers[0].count / layout[0]
    return stride(from: 0, to: total, by: frames).map { start in
        let count = min(frames, total - start)
        return InputRecord(
            sampleTime: sampleStart + Double(start), hostTimeNanos: hostStart + UInt64(Double(start) / rate * 1e9),
            frameCount: count, nominalRate: rate,
            buffers: zip(buffers, layout).map { buffer, channels in
                Array(buffer[(start * channels)..<((start + count) * channels)])
            })!
    }
}

/// Polls `condition` every 10 ms. After `limit`, it records `message` as a test failure. It
/// checks once more after a sleep past the limit, so a main-actor job that another test held
/// back (a report hop) runs before the last check.
@MainActor
func until(limit: Duration = .seconds(1), _ message: String, _ condition: () -> Bool) async {
    let end = ContinuousClock.now + limit
    var expired = false
    while !condition() {
        guard !expired else {
            Issue.record("\(message) (limit \(limit))")
            return
        }
        expired = ContinuousClock.now >= end
        try? await Task.sleep(for: .milliseconds(10))
    }
}
