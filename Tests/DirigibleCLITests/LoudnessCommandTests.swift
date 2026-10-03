import AVFoundation
import DirigibleCore
import Foundation
import Testing

/// `dirigible loudness` (run 8a criterion 12). Each WAV holds a 1 kHz sine at -23 dBFS in each
/// channel, which reads -23.0 LUFS in stereo.
struct LoudnessCommandTests {
    /// A 32-bit float WAV of `seconds` of the sine at `dBFS`, with the same phase in each channel.
    static func writeWAV(
        _ url: URL, seconds: Double, rate: Int = 48_000, channels: Int = 2, dBFS: Double = -23
    ) throws {
        let frames = Int(seconds * Double(rate))
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels)))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let amplitude = pow(10, dBFS / 20)
        for channel in 0..<channels {
            for frame in 0..<frames {
                buffer.floatChannelData![channel][frame] = Float(
                    amplitude * sin(2 * .pi * 1000 * Double(frame) / Double(rate)))
            }
        }
        try file.write(from: buffer)
    }

    /// Track `t1`: `loud` (+7 dB) and `plain` (0 dB) of `f1.wav`. Track `t2`: `cut` of `short.wav`,
    /// which has 5 s where the pool says 10 s; `gone` of `gone.wav`, which is not on the disk; and
    /// `other` of `other.wav`, which is at 44.1 kHz.
    static func package() throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        for (id, length) in [("f1", 480_000), ("short", 480_000), ("gone", 480_000), ("other", 480_000)] {
            try session.addFile(AudioFile(id: FileID(id), path: "\(id).wav", layout: .stereo, length: Frames(length)))
        }
        try session.addTrack("t1", name: "Host", layout: .stereo)
        try session.addTrack("t2", name: "Guest", layout: .stereo)
        try session.place(Clip(id: "plain", file: "f1", start: 480_000, offset: 0, length: 480_000), on: "t1")
        try session.place(
            Clip(id: "loud", file: "f1", start: 0, offset: 0, length: 480_000, gain: Gain(dB: 7)!), on: "t1")
        try session.place(Clip(id: "cut", file: "short", start: 0, offset: 0, length: 480_000), on: "t2")
        try session.place(Clip(id: "gone", file: "gone", start: 480_000, offset: 0, length: 480_000), on: "t2")
        try session.place(Clip(id: "other", file: "other", start: 960_000, offset: 0, length: 480_000), on: "t2")
        let package = try TemporaryPackage(session)
        let clips = package.url.appending(path: "Clips")
        try writeWAV(clips.appending(path: "f1.wav"), seconds: 10)
        try writeWAV(clips.appending(path: "short.wav"), seconds: 5)
        try writeWAV(clips.appending(path: "other.wav"), seconds: 10, rate: 44_100)
        return package
    }

    @Test func eachClipInTimelineOrder() async throws {
        let package = try Self.package()
        let before = try package.xml()
        let expected = "loud\t-16.0 LUFS\nplain\t-23.0 LUFS\ncut\t-23.0 LUFS\tshort\ngone\tmissing\nother\tunreadable\n"
        let all = try await package.run("loudness", "PKG")
        #expect(all == CLIResult(status: 0, stdout: expected, stderr: ""), "all clips: \(all)")
        let two = try await package.run("loudness", "PKG", "plain", "loud")
        #expect(
            two == CLIResult(status: 0, stdout: "loud\t-16.0 LUFS\nplain\t-23.0 LUFS\n", stderr: ""),
            "two clips: \(two)")
        #expect(try package.xml() == before, "the command changed session.xml")
    }

    @Test func unknownClipExitsTwo() async throws {
        let package = try Self.package()
        #expect(
            try await package.run("loudness", "PKG", "loud", "nope")
                == CLIResult(status: 2, stdout: "", stderr: "Error: no clip \"nope\".\n"))
    }

    /// Writes `rate` in the fmt chunk of a WAV. `AVAudioFile` writes a WAV at 3 000 Hz as 8 000 Hz,
    /// but it reads a WAV with 3 000 in its header at 3 000 Hz (run 8a probe, 2026-10-03).
    static func setRate(_ url: URL, _ rate: UInt32) throws {
        var data = try Data(contentsOf: url)
        let fmt = try #require(data.range(of: Data("fmt ".utf8))).lowerBound
        let blockAlign = UInt32(data[fmt + 20]) | UInt32(data[fmt + 21]) << 8
        for (offset, value) in [(fmt + 12, rate), (fmt + 16, rate * blockAlign)] {
            for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(byte))) }
        }
        try data.write(to: url)
    }

    /// The meter refuses 3 000 Hz: the shelf of the K-weighting is over Nyquist.
    @Test func rateTheMeterRefusesPrintsNone() async throws {
        var session = Session(sampleRate: 3_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .stereo, length: 30_000))
        try session.addTrack("t1", name: "Host", layout: .stereo)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 30_000), on: "t1")
        let package = try TemporaryPackage(session)
        let wav = package.url.appending(path: "Clips/f1.wav")
        try Self.writeWAV(wav, seconds: 3.75, rate: 8_000)
        try Self.setRate(wav, 3_000)
        let result = try await package.run("loudness", "PKG")
        #expect(result == CLIResult(status: 0, stdout: "c1\tnone\n", stderr: ""), "3 000 Hz: \(result)")
    }
}
