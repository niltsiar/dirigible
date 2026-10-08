import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// `clip paste --source` and `clip paste-clips --source` (decision 0042, C15), and the `source`
/// argument of their MCP tools. P has track t1 with clips A (0..<24 000) and C (24 000..<48 000)
/// of file take1-mic (1 s, a tone). Q has track u1 and its own take1-mic (1 s of silence).
struct PasteFromCommandTests {
    let p: TemporaryPackage
    let q: TemporaryPackage

    init() throws {
        p = try Self.package(tone: true, track: "t1", rate: 48_000)
        q = try Self.package(tone: false, track: "u1", rate: 48_000)
    }

    /// A package with one 24-bit WAV `take1-mic` and track `track` with clips A and C of it.
    static func package(tone: Bool, track: TrackID, rate: Int) throws -> TemporaryPackage {
        let package = try TemporaryPackage()
        let clips = package.url.appending(path: clipsFolderName)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
        buffer.frameLength = AVAudioFrameCount(rate)
        for n in 0..<rate { buffer.floatChannelData![0][n] = tone ? Float(0.25 * sin(Double(n) / 7.6)) : 0 }
        let writer = try ClipWriter(url: clips.appending(path: "take1-mic.wav"), file: "take1-mic.wav", format: format)
        try writer.write(buffer)
        try writer.close()
        var session = Session(sampleRate: rate)
        try session.addFile(AudioFile(id: "take1-mic", path: "take1-mic.wav", layout: .mono, length: Frames(rate)))
        try session.addTrack(track, name: track.rawValue, layout: .mono)
        let half = Frames(rate / 2)
        try session.place(Clip(id: "A", file: "take1-mic", start: 0, offset: 0, length: half), on: track)
        try session.place(Clip(id: "C", file: "take1-mic", start: half, offset: half, length: half), on: track)
        try session.write(to: package.url)
        return package
    }

    func names(_ package: TemporaryPackage) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: clipsFolderName).path))
            ?? []).sorted()
    }

    func bytes(_ package: TemporaryPackage, _ name: String) -> Data? {
        FileManager.default.contents(atPath: package.url.appending(path: "\(clipsFolderName)/\(name)").path)
    }

    /// C15a: the range form copies the file under a new ID and prints the pasted IDs.
    @Test func pasteFromAnotherPackageCopiesTheFiles() async throws {
        let result = try await q.run(
            "clip", "paste", "PKG", "--source", p.path, "--track", "t1", "--from", "0", "--to", "48000", "--at",
            "96000", "--onto", "u1")

        #expect(result == CLIResult(status: 0, stdout: "A@96000\nC@120000\n", stderr: ""))
        #expect(names(q) == ["take1-mic 2.wav", "take1-mic.wav"])
        #expect(bytes(q, "take1-mic 2.wav") == bytes(p, "take1-mic.wav"))
        let session = try q.read()
        #expect(session.clip("A@96000")?.clip.file == "take1-mic 2" && session.clip("C@120000")?.clip.offset == 24_000)
    }

    /// The --onto rule: another package needs it (exit 64), and nothing changes.
    @Test func aForeignSourceNeedsOnto() async throws {
        let before = try q.xml()
        let result = try await q.run(
            "clip", "paste", "PKG", "--source", p.path, "--track", "t1", "--from", "0", "--to", "48000", "--at", "0")

        #expect(result.status == 64 && result.stderr.contains("Give --onto with --source of another package."))
        #expect(try q.xml() == before && names(q) == ["take1-mic.wav"])
    }

    /// C15b: the clip set form.
    @Test func pasteClipsFromAnotherPackage() async throws {
        let result = try await q.run("clip", "paste-clips", "PKG", "C", "--source", p.path, "--at", "0", "--onto", "u1")

        #expect(result == CLIResult(status: 0, stdout: "C@0\n", stderr: ""))
        let session = try q.read()
        #expect(session.clip("C@0")?.clip.file == "take1-mic 2" && names(q).count == 2)
    }

    /// C15c: a source that is the target is the paste of today: no copy, no --onto needed.
    @Test func sourceOfTheSamePackageCopiesNothing() async throws {
        _ = try await q.run("info", "PKG")
        let result = try await q.run(
            "clip", "paste", "PKG", "--source", q.path, "--track", "u1", "--from", "0", "--to", "24000", "--at",
            "48000")

        #expect(result == CLIResult(status: 0, stdout: "A@48000\n", stderr: ""))
        let session = try q.read()
        #expect(names(q) == ["take1-mic.wav"] && session.clip("A@48000")?.clip.file == "take1-mic")
    }

    /// C15d: a missing source file exits 2 with the file name; nothing changes.
    @Test func aMissingSourceFails() async throws {
        try FileManager.default.removeItem(at: p.url.appending(path: "\(clipsFolderName)/take1-mic.wav"))
        let before = try q.xml()

        let result = try await q.run("clip", "paste-clips", "PKG", "A", "--source", p.path, "--at", "0", "--onto", "u1")

        #expect(result.status == 2 && result.stderr.contains("take1-mic.wav"), "\(result.stderr)")
        #expect(try q.xml() == before && names(q) == ["take1-mic.wav"])
    }

    /// C15f: a source at 44 100 Hz converts to the rate of the target.
    @Test func sourceOfAnotherRateConverts() async throws {
        let slow = try Self.package(tone: true, track: "t1", rate: 44_100)

        let result = try await q.run(
            "clip", "paste-clips", "PKG", "A", "--source", slow.path, "--at", "0", "--onto", "u1")

        #expect(result == CLIResult(status: 0, stdout: "A@0\n", stderr: ""))
        let session = try q.read()
        let file = try #require(session.files["take1-mic 2"])
        #expect(abs(file.length.count - 48_000) <= 1 && session.clip("A@0")?.clip.length == 24_000)
    }

    /// C15e, C15g: the tools take `source`, run as typed work under the lock, and say in their text
    /// that a call runs to the end.
    @Test func thePasteToolsTakeSource() async throws {
        let answers = try await mcp([
            toolCall(
                1, "clip_paste_clips", ["package": q.path, "clips": ["A"], "at": 0, "onto": ["u1"], "source": p.path]),
            toolCall(2, "clip_paste_clips", ["package": q.path, "clips": ["A"], "at": 0, "source": p.path]),
            toolCall(
                3, "clip_paste_clips", ["package": q.path, "clips": ["A"], "at": 0, "source": "relative.dirigible"]),
        ])

        #expect(toolResult(answer(answers, id: 1)) == ("A@0", false))
        #expect(toolResult(answer(answers, id: 2)) == ("Give onto with source of another package.", true))
        #expect(toolResult(answer(answers, id: 3)) == ("The argument \"source\" must be an absolute path.", true))
        #expect(names(q) == ["take1-mic 2.wav", "take1-mic.wav"])
        let tools = try await mcp([modernRequest(9, "tools/list", [:])])
        let text = String(describing: answer(tools, id: 9))
        #expect(text.contains("runs to the end and saves") && text.contains("Read session_info before a retry"))
    }
}
