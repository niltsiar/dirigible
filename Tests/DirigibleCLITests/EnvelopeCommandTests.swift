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

    /// A range gain with a frame or a ramp outside `0...2^40` is a session refusal (exit 1), not a
    /// crash on an `Int` overflow, and `session.xml` keeps its bytes.
    @Test(arguments: [
        ["--from", "0", "--to", "10", "--ramp", "9223372036854775807"],
        ["--from", "0", "--to", "9223372036854775807"],
        ["--from", "-1", "--to", "10"],
    ])
    func aRangeGainOutOfRangeExits1(bounds: [String]) async throws {
        let before = try package.xml()
        let result = try await package.run(["clip", "gain-range", "PKG", "--track", "t1", "--db", "-6"] + bounds)
        #expect(result == CLIResult(status: 1, stdout: "", stderr: "Error: a frame is negative or more than 2^40.\n"))
        #expect(try package.xml() == before)
    }

    /// C6: a set and a clear by the CLI keep the points outside the clip window in `session.xml`,
    /// and `info` shows the points inside the window in timeline frames, the count outside it, and
    /// the gain at the first and the last frame of the window.
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
        let edges = "2 points outside the clip, window edges 10000:-7.5 49999:-10.09\n"
        #expect(info.stdout.contains("0.0 dB envelope 15000:-12.0, " + edges), "\(info.stdout)")
        let json = try await package.run("info", "PKG", "--json", "--compact")
        #expect(json.stdout.contains(#""points" : 3,"#) && !json.stdout.contains("windowEdges"), "\(json.stdout)")

        let clear = try await package.run("clip", "envelope", "PKG", "c1", "--clear")
        #expect(clear.status == 0, "\(clear)")
        #expect(try package.read().clip("c1")?.clip.envelope.points.map(\.frame.count) == [5_000, 70_000])
        let cleared = try await package.run("info", "PKG")
        #expect(
            cleared.stdout.contains("0.0 dB 2 points outside the clip, window edges 10000:-3.46 49999:-7.15\n"),
            "\(cleared.stdout)")
    }

    /// The window edges of the first `info` clip line and of its JSON, as the key `windowEdges`.
    private func windowEdges(of clip: String) async throws -> (text: String, json: [[Double]]?) {
        struct View: Decodable {
            struct Track: Decodable {
                struct Clip: Decodable {
                    let id: String
                    let windowEdges: [[Double]]?
                }
                let clips: [Clip]
            }
            let tracks: [Track]
        }
        let text = try await package.run("info", "PKG")
        let json = try await package.run("info", "PKG", "--json")
        try #require(text.status == 0 && json.status == 0)
        let view = try JSONDecoder().decode(View.self, from: Data(json.stdout.utf8))
        let line = text.stdout.split(separator: "\n").first { $0.contains("clip \(clip) ") }
        return (String(try #require(line)), view.tracks.flatMap(\.clips).first { $0.id == clip }?.windowEdges)
    }

    /// C4: a clip with its points all inside the window, and a clip with no point, show no window
    /// edges in the text or in the JSON.
    @Test func anInsideOnlyEnvelopeShowsNoWindowEdges() async throws {
        let inside = GainEnvelope([GainEnvelope.Point(frame: 20_000, gain: Gain(dB: -6)!)])!
        try package.edit { session in
            try session.removeClips(["c1"])
            try session.place(
                Clip(id: "c1", file: "f1", start: 10_000, offset: 10_000, length: 40_000, envelope: inside), on: "t1")
            try session.place(Clip(id: "c2", file: "f1", start: 60_000, offset: 60_000, length: 40_000), on: "t1")
        }
        for id in ["c1", "c2"] {
            let (text, json) = try await windowEdges(of: id)
            #expect(!text.contains("window edges") && json == nil, "\(id): \(text) \(String(describing: json))")
        }
    }

    /// C6: an edge gain that rounds to zero shows 0.0 in the text and 0 in the JSON, not a
    /// negative zero. At file frame 10 000 the envelope is -0.004 dB, and at 49 999 it is -0.02 dB.
    @Test func aWindowEdgeNearZeroShowsZero() async throws {
        let points = [(0, 0.0), (100_000, -0.04)].map {
            GainEnvelope.Point(frame: Frames($0.0), gain: Gain(dB: $0.1)!)
        }
        try package.edit { session in
            try session.removeClips(["c1"])
            try session.place(
                Clip(
                    id: "c1", file: "f1", start: 10_000, offset: 10_000, length: 40_000,
                    envelope: GainEnvelope(points)!),
                on: "t1")
        }
        let (text, json) = try await windowEdges(of: "c1")
        #expect(text.hasSuffix("2 points outside the clip, window edges 10000:0.0 49999:-0.02"), "\(text)")
        let edges = try #require(json)
        #expect(edges == [[10_000, 0], [49_999, -0.02]] && edges[0][1].sign == .plus, "\(edges)")
    }
}
