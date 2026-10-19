import AVFoundation
import DirigibleCore
import Foundation
import Testing

/// `dirigible clip envelope` and `dirigible clip gain-range` (decision 0060, C6 and C7). Track `t1`
/// has clip `c1`, which plays `f1.wav` from frame 0 at timeline frame 0: 3 s of a 1 kHz sine at
/// -6 dBFS.
struct EnvelopeCommandTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 144_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 144_000), on: "t1")
        package = try TemporaryPackage(session)
        try LoudnessCommandTests.writeWAV(
            package.url.appending(path: "Clips/f1.wav"), seconds: 3, channels: 1, dBFS: -6)
    }

    /// The level in dB of the export `wav` at `frame`, against its level at frame 0: the peak of
    /// one sine period before and one after the frame, over the peak of the first period.
    static func level(_ wav: URL, at frames: [Int]) throws -> [Double] {
        let file = try AVAudioFile(forReading: wav)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        func peak(_ range: Range<Int>) -> Double { Double(samples[range].map(abs).max() ?? 0) }
        let reference = peak(0..<48)
        return frames.map { 20 * log10(peak(($0 - 48)..<($0 + 48)) / reference) }
    }

    /// C6: points 0:0 and 48000:-16 by the CLI; the export is -8.0 dB at the ramp middle and
    /// -16.0 dB after the last point.
    @Test func anEnvelopeSetByTheCLIExportsTheRamp() async throws {
        let set = try await package.run("clip", "envelope", "PKG", "c1", "--point", "0:0", "--point", "48000:-16")
        #expect(set == CLIResult(status: 0, stdout: "", stderr: ""))
        let wav = package.folder.appending(path: "out.wav")
        #expect(try await package.run("export", "PKG", "--out", wav.path).status == 0)
        let levels = try Self.level(wav, at: [24_000, 60_000, 120_000])
        #expect(abs(levels[0] + 8) <= 0.05 && abs(levels[1] + 16) <= 0.05 && abs(levels[2] + 16) <= 0.05, "\(levels)")
    }

    /// C7: -16 dB on 48 000..<96 000 with 24 000-frame ramps: -16 dB inside, -8 dB at the ramp
    /// middle, and 0 dB outside the ramps. The command writes the ID of the changed clip.
    @Test func aRangeGainExportsATrapezoid() async throws {
        let range = try await package.run(
            "clip", "gain-range", "PKG", "--track", "t1", "--from", "48000", "--to", "96000", "--db", "-16", "--ramp",
            "24000")
        #expect(range == CLIResult(status: 0, stdout: "c1\n", stderr: ""))
        let wav = package.folder.appending(path: "out.wav")
        #expect(try await package.run("export", "PKG", "--out", wav.path).status == 0)
        let levels = try Self.level(wav, at: [12_000, 36_000, 72_000, 107_999, 132_000])
        let expected = [0.0, -8, -16, -8, 0]
        #expect(zip(levels, expected).allSatisfy { abs($0 - $1) <= 0.05 }, "\(levels)")
    }

    /// The default ramp of a range gain is 500 ms at the session rate: 24 000 frames at 48 kHz.
    @Test func aRangeGainHasHalfSecondRampsByDefault() async throws {
        let range = try await package.run(
            "clip", "gain-range", "PKG", "--track", "t1", "--from", "48000", "--to", "96000", "--db", "-6")
        #expect(range.status == 0, "\(range)")
        let points = try package.read().clip("c1")?.clip.envelope.points.map(\.frame.count)
        #expect(points == [24_000, 48_000, 95_999, 119_999])
    }

    /// C6: a frame outside the clip is a session refusal (exit 1, decision 0011) that names the
    /// clip range, and `session.xml` keeps its bytes. A point that does not parse is a usage error
    /// (exit 64).
    @Test func aFrameOutsideTheClipExits1() async throws {
        let before = try package.xml()
        let outside = try await package.run("clip", "envelope", "PKG", "c1", "--point", "0:0", "--point", "144000:-6")
        #expect(
            outside
                == CLIResult(
                    status: 1, stdout: "",
                    stderr:
                        "Error: frame 144000 is not inside clip \"c1\", which plays the timeline frames 0..<144000.\n"
                ))
        #expect(try package.xml() == before)
        for point in ["10", "x:0", "10:-200", "10:nan"] {
            let bad = try await package.run("clip", "envelope", "PKG", "c1", "--point", point)
            #expect(
                bad.status == 64
                    && bad.stderr.contains("A point is <frame>:<dB>, with a frame 0 or more and a gain from -96 to 96."),
                "\(point): \(bad)")
        }
        let twice = try await package.run("clip", "envelope", "PKG", "c1", "--point", "10:0", "--point", "10:-3")
        #expect(twice.status == 64 && twice.stderr.contains("Frame 10 is given twice."), "\(twice)")
        let neither = try await package.run("clip", "envelope", "PKG", "c1")
        #expect(neither.status == 64 && neither.stderr.contains("Give --point or --clear."), "\(neither)")
        #expect(try package.xml() == before)
    }

    /// C6: a set and a clear by the CLI keep the points outside the clip window in `session.xml`,
    /// and `info` shows the points inside the window in timeline frames and the count outside it.
    @Test func aSetKeepsThePointsOutsideTheClipWindow() async throws {
        // The clip plays file frames 10 000..<50 000 at timeline frame 10 000.
        let points = [(5_000, -3.0), (20_000, -6), (70_000, -9)].map {
            GainEnvelope.Point(frame: Frames($0.0), gain: Gain(dB: $0.1)!)
        }
        try package.edit { session in
            try session.removeClips(["c1"])
            try session.place(
                Clip(
                    id: "c1", file: "f1", start: 10_000, offset: 10_000, length: 40_000, envelope: GainEnvelope(points)!
                ),
                on: "t1")
        }
        let set = try await package.run("clip", "envelope", "PKG", "c1", "--point", "15000:-12")
        #expect(set.status == 0, "\(set)")
        #expect(
            try package.read().clip("c1")?.clip.envelope.points.map { [$0.frame.count, Int($0.gain.dB)] } == [
                [5_000, -3], [15_000, -12], [70_000, -9],
            ])
        let info = try await package.run("info", "PKG")
        #expect(info.stdout.contains("0.0 dB envelope 15000:-12.0, 2 points outside the clip\n"), "\(info.stdout)")
        let json = try await package.run("info", "PKG", "--json", "--compact")
        #expect(json.stdout.contains(#""points" : 3,"#), "\(json.stdout)")

        let clear = try await package.run("clip", "envelope", "PKG", "c1", "--clear")
        #expect(clear.status == 0, "\(clear)")
        #expect(try package.read().clip("c1")?.clip.envelope.points.map(\.frame.count) == [5_000, 70_000])
    }
}
