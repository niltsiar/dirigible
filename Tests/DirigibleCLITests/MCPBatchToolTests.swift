import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The tool `batch` on a closed package (decision 0063): many edit calls as one read-edit-save.
/// Fixture: 48 kHz, track `V` (mono), clip `a` (file `f`, 0 to 96000).
struct MCPBatchToolTests {
    let package: TemporaryPackage

    init() throws { package = try Self.fixture() }
    init(package: TemporaryPackage) { self.package = package }

    static func fixture() throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("V", name: "Voice", layout: .mono)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 96_000))
        try session.place(Clip(id: "a", file: "f", start: 0, offset: 0, length: 96_000), on: "V")
        return try TemporaryPackage(session)
    }

    /// One call of a batch.
    static func call(_ tool: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
        ["tool": tool, "arguments": arguments]
    }

    static var addT2: [String: Any] { call("track_add", ["id": "T2", "name": "A", "layout": "mono"]) }
    static var fade: [String: Any] { call("clip_fade", ["clip": "a", "in": 480]) }
    static var badRename: [String: Any] { call("track_rename", ["track": "X", "name": "Y"]) }

    /// What a refused batch must leave: the bytes of `session.xml` and the names in `Backups/`.
    struct Snapshot: Equatable {
        let xml: Data
        let backups: [String]
    }

    func snapshot() throws -> Snapshot {
        let backups = try? FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: "Backups").path)
        return Snapshot(xml: try package.xml(), backups: (backups ?? []).sorted())
    }

    func batch(_ calls: [[String: Any]]) async throws -> (text: String, isError: Bool) {
        try await tool("batch", ["calls": calls])
    }

    func tool(_ name: String, _ arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
        let answers = try await mcp([toolCall(1, name, arguments.merging(["package": package.path]) { $1 })])
        return toolResult(answer(answers, id: 1))
    }

    /// C3: a refused call at the start, the middle, or the end leaves the file as it was, and the
    /// lock is free for the next call.
    @Test(arguments: [0, 1, 2]) func aFailedCallLeavesTheFile(index: Int) async throws {
        var calls = [Self.addT2, Self.fade]
        calls.insert(Self.badRename, at: index)
        let before = try snapshot()

        let result = try await batch(calls)

        let text = "calls[\(index)] track_rename failed, so the batch changed nothing: no track \"X\"."
        #expect(result == (text, true), "BATCH-S2-1 \(result)")
        #expect(try snapshot() == before, "BATCH-S2-2 the failed batch changed the file")
        let next = try await tool("track_rename", ["track": "V", "name": "Z"])
        #expect(next == ("OK", false), "the lock stayed: \(next)")
    }

    /// C4: the three steps are in the file after one call.
    @Test func aBatchSavesOnce() async throws {
        let before = try snapshot()
        let calls = [Self.addT2, Self.call("track_rename", ["track": "T2", "name": "B"]), Self.fade]

        let result = try await batch(calls)

        #expect(!result.isError, "\(result)")
        let session = try package.read()
        #expect(session.track("T2")?.name == "B")
        #expect(session.clip("a")?.clip.fades.fadeIn == Frames(480))
        #expect(try snapshot().backups.count <= before.backups.count + 1, "BATCH-S2-3 the batch saved more than once")
    }

    /// C5: one line for each result line, on the index of the call.
    @Test func theResultHasALineForEachResultLine() async throws {
        let calls = [
            Self.addT2, Self.call("track_add_call", ["host_id": "H", "guest_id": "G"]), Self.fade,
        ]

        let result = try await batch(calls)

        let lines = ["calls[0] track_add: T2", "calls[1] track_add_call: H", "calls[1] track_add_call: G"]
        #expect(result == ((lines + ["calls[2] clip_fade: OK"]).joined(separator: "\n"), false), "\(result)")
    }

    /// C6: the 29 tools with the role `.alone`.
    static let alone = [
        "session_create", "session_info", "episode_get", "file_prune", "backup_list", "backup_revert",
        "clip_split_stereo", "transcript_import", "transcript_words", "transcript_export", "take_map", "record",
        "transport_play", "transport_stop", "transport_locate", "loudness", "export", "render", "level", "duck",
        "import", "silences", "nearest_pause", "meter", "chapters_export", "chapters_import", "devices", "apps",
        "batch",
    ]

    /// C6: a call that is not a step is refused at its index before any step runs.
    @Test(arguments: alone) func anAloneToolIsRefused(tool: String) async throws {
        let before = try snapshot()

        let result = try await batch([Self.addT2, Self.call(tool)])

        let reason =
            tool == "batch"
            ? "a batch cannot hold a batch." : "\(tool) cannot run in a batch: a step is an edit of session.xml only."
        #expect(result == ("calls[1] \(tool) failed, so the batch changed nothing: \(reason)", true), "\(result)")
        #expect(try snapshot() == before)
    }

    /// C6: a tool that is a step, with a call that copies a file.
    @Test(arguments: ["clip_paste", "clip_paste_clips", "marker_set", "episode_set"])
    func aCallThatCopiesAFileIsRefused(name: String) async throws {
        let before = try snapshot()
        let arguments: [String: Any] =
            switch name {
            case "clip_paste": ["from": 0, "to": 10, "track": ["V"], "at": 0, "source": package.path]
            case "clip_paste_clips": ["clips": ["a"], "at": 0, "source": package.path]
            case "marker_set": ["id": "M", "name": "A", "at": 0, "image": "/image.png"]
            default: ["artwork": "/image.png"]
            }

        let result = try await batch([Self.addT2, Self.call(name, arguments)])

        let reason = "\(name) cannot run in a batch: a step is an edit of session.xml only."
        #expect(result == ("calls[1] \(name) failed, so the batch changed nothing: \(reason)", true), "\(result)")
        #expect(try snapshot() == before)
    }

    /// C6: an unknown tool, a bad argument, and an inner `package` give the text of the call alone.
    @Test func aCallThatDoesNotCheckIsRefused() async throws {
        let before = try snapshot()
        let unknown = try await batch([Self.addT2, Self.call("clip_explode")])
        #expect(unknown == ("calls[1] clip_explode failed, so the batch changed nothing: no tool clip_explode.", true))

        let arguments: [String: Any] = ["clip": "a", "in": "x"]
        let alone = try await tool("clip_fade", arguments)
        let bad = try await batch([Self.addT2, Self.call("clip_fade", arguments)])
        #expect(bad == ("calls[1] clip_fade failed, so the batch changed nothing: \(alone.text)", true), "\(bad)")

        let inner = try await batch([Self.call("track_add", ["package": package.path, "name": "A", "layout": "mono"])])
        let reason = "The argument \"package\" belongs to the batch, not to a call."
        #expect(inner == ("calls[0] track_add failed, so the batch changed nothing: \(reason)", true), "\(inner)")
        #expect(try snapshot() == before)
    }

    /// C7: 1 and 100 calls pass. 0 and 101 are refused with the text of the argument, and the
    /// schema shows both limits.
    @Test func theCountLimitIsOneToAHundred() async throws {
        let rename = { (name: String) in Self.call("track_rename", ["track": "V", "name": name]) }
        let one = try await batch([rename("One")])
        #expect(one == ("calls[0] track_rename: OK", false), "\(one)")
        let hundred = try await batch((0..<100).map { rename("N\($0)") })
        #expect(!hundred.isError && hundred.text.split(separator: "\n").count == 100, "\(hundred.text.prefix(200))")
        #expect(try package.read().track("V")?.name == "N99")

        let before = try snapshot()
        let text = "The argument \"calls\" must be an array of 1 to 100 calls."
        for count in [0, 101] {
            let refused = try await batch((0..<count).map { rename("R\($0)") })
            #expect(refused == (text, true), "BATCH-S2-4 \(count) calls: \(refused)")
        }
        #expect(try snapshot() == before)

        let answers = try await mcp([modernRequest(1, "tools/list")])
        let tools = result(answer(answers, id: 1))["tools"] as? [[String: Any]] ?? []
        let schema = tools.first { $0["name"] as? String == "batch" }?["inputSchema"] as? [String: Any]
        let calls = (schema?["properties"] as? [String: Any])?["calls"] as? [String: Any]
        #expect(calls?["minItems"] as? Int == 1 && calls?["maxItems"] as? Int == 100, "\(String(describing: calls))")
    }

    /// Take 1 with a 2.0 s segment on `t1` and on `t2`, finalized, so both are placed. The clip of
    /// `take1-2-1` is cleared, so `file_remove take1-2-1` splits the take (decision 0037).
    static func takePackage() async throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        let start = PlaceCommandTests.takeStart
        try session.setRecording(
            Recording(take: 1, playheadFrame: 96_000, takeStartHostTimeNanos: start, armedTracks: ["t1", "t2"]))
        let package = try TemporaryPackage(session)
        let capture = package.url.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        for arm in [1, 2] {
            let header = CaptureHeader(
                deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
                channelCount: 1, latency: 0, firstSampleTime: 0, firstHostTimeNanos: start + 10_000_000)
            let writer = try SegmentWriter(
                folder: capture, name: SegmentName(take: 1, arm: arm, segment: 1), header: header)
            try writer.checkpoint(Checkpoint(fileFrame: 0, sampleTime: 0, hostTimeNanos: start + 10_000_000))
            try [Float](repeating: 0.25, count: 96_000).withUnsafeBufferPointer { try writer.write($0, frames: 96_000) }
            try writer.close()
        }
        let finalized = try await package.run("take", "finalize", "PKG")
        let cleared = try await package.run("clip", "clear", "PKG", "--track", "t2", "--from", "0", "--to", "1000000")
        guard finalized.status == 0, cleared.status == 0 else { throw POSIXError(.EIO) }
        return package
    }

    static var splitThenRipple: [[String: Any]] {
        [call("file_remove", ["file": "take1-2-1"]), call("clip_ripple_delete", ["from": [0], "to": [4800]])]
    }

    /// C8: a step that splits a take blocks a later ripple step, as the same two calls one by one.
    @Test func aStepThatSplitsATakeBlocksALaterRipple() async throws {
        let take = MCPBatchToolTests(package: try await Self.takePackage())
        let before = try take.snapshot()

        let result = try await take.batch(Self.splitThenRipple)

        let text = "calls[1] clip_ripple_delete failed, so the batch changed nothing: "
        #expect(result == (text + splitTakeMessage(take.package.path), true), "BATCH-S2-5 \(result)")
        #expect(try take.snapshot() == before)

        let removed = try await take.tool("file_remove", ["file": "take1-2-1"])
        let ripple = try await take.tool("clip_ripple_delete", ["from": [0], "to": [4800]])
        #expect(removed == ("OK", false) && ripple == (splitTakeMessage(take.package.path), true), "\(ripple)")
    }

    /// C9: a pending take refuses the whole batch with the text of one call and no index.
    @Test func aPendingTakeRefusesTheBatch() async throws {
        try package.edit {
            try $0.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["V"]))
        }
        let before = try snapshot()

        let result = try await batch([Self.addT2])

        #expect(result == (pendingTakeMessage(package.path), true), "\(result)")
        #expect(try snapshot() == before)
    }

    /// C11: a later call sees the session that the calls before it made.
    @Test func aLaterCallSeesAnEarlierCall() async throws {
        let marker = { (name: String, extra: [String: Any]) in
            Self.call("marker_set", ["id": "M", "name": name].merging(extra) { $1 })
        }
        let pair = try await batch([marker("A", ["at": 0]), marker("B", [:])])
        #expect(!pair.isError, "\(pair)")
        #expect(try package.read().markers["M"]?.name == "B" && package.read().markers["M"]?.position == 0)

        let emptyImage = try await batch([marker("C", ["at": 5, "image": ""]), marker("D", [:])])
        #expect(!emptyImage.isError, "an empty image clears the field and is a step: \(emptyImage)")
        #expect(try package.read().markers["M"]?.name == "D")

        let tracks = try await batch([Self.addT2, Self.call("track_rename", ["track": "T2", "name": "B"])])
        #expect(tracks == ("calls[0] track_add: T2\ncalls[1] track_rename: OK", false), "\(tracks)")
    }
}
