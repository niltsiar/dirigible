import DirigibleCore
import Foundation
import Testing

/// The take sync note of an MCP edit on a closed package (decision 0061, C7). The open-window
/// cases are in `LiveTakeSyncNoteTests`.
struct MCPTakeSyncNoteTests {
    /// Take 1 on `t1` from 0 to 48 000, in sync at offset 0.
    static func oneTake() throws -> TemporaryPackage {
        try TakeMapCommandTests.takes([(1, TakeMapCommandTests.takeStart, 0)])
    }

    static func insert(_ id: Int, _ path: String, at: Int, track: [String] = ["t1"]) -> String {
        toolCall(id, "clip_ripple_insert", ["package": path, "at": at, "length": 24_000, "track": track])
    }

    static let broken = "Take sync: take 1 in sync, offset 0.000 s -> broken from 0:00:00.750 (2 shifts)"

    /// An insert inside the take clip on `t1` moves its second part: one line. A second insert
    /// keeps the take broken: no line.
    @Test func aRippleInsertReportsTheBreakOnce() async throws {
        let package = try Self.oneTake()

        let answers = try await mcp([
            Self.insert(1, package.path, at: 12_000), Self.insert(2, package.path, at: 6_000),
        ])

        #expect(toolResult(answer(answers, id: 1)) == ("OK\n" + Self.broken, false))
        #expect(toolResult(answer(answers, id: 2)) == ("OK", false))
    }

    /// An insert at 0 on all tracks moves the whole take: the offset line.
    @Test func anInsertAtZeroGivesTheOffsetLine() async throws {
        let package = try Self.oneTake()

        let answers = try await mcp([Self.insert(1, package.path, at: 0, track: [])])

        #expect(
            toolResult(answer(answers, id: 1))
                == ("OK\nTake sync: take 1 offset 0.000 s -> 0.500 s (+0.500 s, +24000 frames)", false))
    }

    /// A move under 1 ms keeps its sign and its size in frames: a 1-frame nudge, then a -10-frame
    /// nudge of the one take clip.
    @Test func aSubMillisecondNudgeShowsItsSignAndFrames() async throws {
        let package = try TakeMapCommandTests.takes([(1, TakeMapCommandTests.takeStart, 48_000)])
        let nudge = { (id: Int, by: Int) in
            toolCall(id, "clip_nudge", ["package": package.path, "clips": ["take1-1-1"], "by": by])
        }

        let answers = try await mcp([nudge(1, 1), nudge(2, -10)])

        #expect(
            toolResult(answer(answers, id: 1))
                == ("OK\nTake sync: take 1 offset 1.000 s -> 1.000 s (+0.000 s, +1 frames)", false))
        #expect(
            toolResult(answer(answers, id: 2))
                == ("OK\nTake sync: take 1 offset 1.000 s -> 1.000 s (-0.000 s, -10 frames)", false))
    }

    /// An insert inside the clip of take 2 breaks only take 2, and the line names take 2.
    @Test func anEditThatBreaksOnlyTake2GivesOneLine() async throws {
        let package = try TakeMapCommandTests.twoTakes()

        let answers = try await mcp([Self.insert(1, package.path, at: 492_000)])

        #expect(
            toolResult(answer(answers, id: 1))
                == ("OK\nTake sync: take 2 in sync, offset 10.000 s -> broken from 0:00:10.750 (2 shifts)", false))
    }

    @Test func noTakeAudioGivesNoLine() async throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        let package = try TemporaryPackage(session)

        let answers = try await mcp([Self.insert(1, package.path, at: 0)])

        #expect(toolResult(answer(answers, id: 1)) == ("OK", false))
    }

    /// `backup_revert` to the session before a break gives the line back to in sync.
    @Test func aRevertFromBrokenToInSyncGivesTheLine() async throws {
        let package = try Self.oneTake()
        let name = "session-20011009T081530.250Z.xml"
        let folder = package.url.appending(path: "Backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try package.xml().write(to: folder.appending(path: name))

        let answers = try await mcp([
            Self.insert(1, package.path, at: 12_000),
            toolCall(2, "backup_revert", ["package": package.path, "name": name]),
        ])

        #expect(toolResult(answer(answers, id: 1)) == ("OK\n" + Self.broken, false))
        #expect(
            toolResult(answer(answers, id: 2))
                == ("OK\nTake sync: take 1 broken from 0:00:00.750 (2 shifts) -> in sync, offset 0.000 s", false))
    }

    /// `clip_paste` from the package itself runs the paste work: a copy of take audio at another
    /// time breaks the take.
    @Test func aPasteOfTakeAudioGivesTheLine() async throws {
        let package = try Self.oneTake()

        let answers = try await mcp([
            toolCall(
                1, "clip_paste",
                [
                    "package": package.path, "from": 0, "to": 12_000, "track": ["t1"], "at": 30_000,
                    "source": package.path,
                ])
        ])

        let result = toolResult(answer(answers, id: 1))
        #expect(!result.isError, "\(result.text)")
        #expect(
            result.text.split(separator: "\n").last
                == "Take sync: take 1 in sync, offset 0.000 s -> broken from 0:00:00.625 (2 shifts)", "\(result.text)")
    }

    /// A transcript import moves no clip, so it gives no line.
    @Test func aTranscriptImportGivesNoLine() async throws {
        let package = try Self.oneTake()
        let vtt = "WEBVTT\n\n00:00:00.100 --> 00:00:00.500\nHello there\n"

        let answers = try await mcp([
            toolCall(1, "transcript_import", ["package": package.path, "text": vtt, "track": "t1"])
        ])

        let result = toolResult(answer(answers, id: 1))
        #expect(!result.isError && !result.text.contains("Take sync"), "\(result.text)")
    }

    /// `episode_set` and `marker_set` move no clip, so they read no anchor: the anchor is a FIFO,
    /// whose open blocks with no writer, so a read would hang the call.
    @Test func anEpisodeOrMarkerCallReadsNoAnchor() async throws {
        let package = try Self.oneTake()
        let anchor = package.url.appending(path: "Capture/take1.anchor")
        try FileManager.default.removeItem(at: anchor)
        #expect(mkfifo(anchor.path, 0o644) == 0)

        let answers = try await mcp([
            toolCall(1, "episode_set", ["package": package.path, "title": "Pilot"]),
            toolCall(2, "marker_set", ["package": package.path, "name": "M", "at": 0, "id": "m"]),
        ])

        #expect(toolResult(answer(answers, id: 1)) == ("OK", false))
        #expect(toolResult(answer(answers, id: 2)) == ("m", false))
    }
}
