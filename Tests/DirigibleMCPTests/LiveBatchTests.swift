import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The tool `batch` on a package that the app has open (decision 0063): the calls are one
/// `Studio.edit`, so they are one undo step of the agent and one autosave. Each call goes over a
/// real socket. Fixture: `LivePackage` (`t1`, `t2`) with file `f` and clip `a` on `t1`, 0 to 96000.
@MainActor
struct LiveBatchTests {
    typealias Call = [String: any Sendable]

    static func call(_ tool: String, _ arguments: Call = [:]) -> Call { ["tool": tool, "arguments": arguments] }
    static let addT2 = call("track_add", ["id": "T2", "name": "A", "layout": "mono"])
    static let fade = call("clip_fade", ["clip": "a", "in": 480])
    static let badRename = call("track_rename", ["track": "X", "name": "Y"])
    static let agent = AgentName(title: "Test Agent", clientName: nil)

    static func package() throws -> LivePackage {
        let package = try LivePackage()
        var session = try Session(contentsOf: package.url)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 96_000))
        try session.place(Clip(id: "a", file: "f", start: 0, offset: 0, length: 96_000), on: "t1")
        try session.write(to: package.url)
        return package
    }

    static func reply(_ text: String, isError: Bool = false) -> AgentBridge.Outcome {
        .reply(.result(text: text, isError: isError))
    }

    static func refused(_ index: Int, _ tool: String, _ text: String) -> AgentBridge.Outcome {
        reply("calls[\(index)] \(tool) failed, so the batch changed nothing: \(text)", isError: true)
    }

    func batch(_ calls: [Call], to socket: URL, package: LivePackage) async -> AgentBridge.Outcome {
        await send(socket, "batch", ["package": package.path, "calls": calls])
    }

    /// C1 and C12: three calls are one undo entry of the agent, and one undo gives the session
    /// before the batch.
    @Test func aBatchIsOneUndoStepOfTheAgent() async throws {
        let package = try Self.package()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let (before, revision) = (studio.session, studio.sessionRevision)

        let outcome = await batch(
            [Self.addT2, Self.call("track_rename", ["track": "T2", "name": "B"]), Self.fade], to: folder.socket,
            package: package)

        #expect(outcome == Self.reply("calls[0] track_add: T2\ncalls[1] track_rename: OK\ncalls[2] clip_fade: OK"))
        #expect(studio.session.track("T2")?.name == "B" && studio.session.clip("a")?.clip.fades.fadeIn == Frames(480))
        #expect(studio.sessionRevision == revision + 1, "BATCH-S3-1 a call made more than one edit")
        #expect(studio.undoAgent == Self.agent)
        try studio.undo()
        #expect(studio.session == before && !studio.canUndo, "BATCH-S3-2 one undo did not restore the session")
        await studio.settle()
    }

    /// C2: a refused call at the start, the middle, or the end changes nothing: no entry, no
    /// revision, no save.
    @Test(arguments: [0, 1, 2]) func aFailedCallChangesNothing(index: Int) async throws {
        let package = try Self.package()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        var calls = [Self.addT2, Self.fade]
        calls.insert(Self.badRename, at: index)
        await studio.settle()
        let (before, revision) = (studio.session, studio.sessionRevision)
        let saved = try Data(contentsOf: package.url.appending(path: "session.xml"))

        let outcome = await batch(calls, to: folder.socket, package: package)

        #expect(outcome == Self.refused(index, "track_rename", "no track \"X\"."), "\(outcome)")
        #expect(studio.session == before && studio.sessionRevision == revision && !studio.canUndo)
        await studio.settle()
        #expect(try Data(contentsOf: package.url.appending(path: "session.xml")) == saved, "BATCH-S3-3 a save")
    }

    /// C5: the result lines are those of the files path.
    @Test func theResultIsTheSameLive() async throws {
        let package = try Self.package()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let calls = [Self.addT2, Self.call("track_add_call", ["host_id": "H", "guest_id": "G"]), Self.fade]

        let outcome = await batch(calls, to: folder.socket, package: package)

        let lines = ["calls[0] track_add: T2", "calls[1] track_add_call: H", "calls[1] track_add_call: G"]
        #expect(outcome == Self.reply((lines + ["calls[2] clip_fade: OK"]).joined(separator: "\n")), "\(outcome)")
        await studio.settle()
    }

    /// C5: the take sync note compares the session before the batch with the one after it: a move
    /// and its undo give no line, and one insert gives the line of a single call.
    @Test func theTakeSyncNoteComparesTheWholeBatch() async throws {
        let package = try LiveTakeMapTests.takePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let move = { (start: Int) in Self.call("clip_move", ["clip": "c1", "track": "t1", "start": start]) }

        let there = await batch([move(144_000), move(96_000)], to: folder.socket, package: package)
        let insert = await batch(
            [Self.call("clip_ripple_insert", ["at": 120_000, "length": 24_000, "track": ["t1"]])], to: folder.socket,
            package: package)

        #expect(there == Self.reply("calls[0] clip_move: OK\ncalls[1] clip_move: OK"), "BATCH-S3-4 \(there)")
        let broken = "Take sync: take 1 in sync, offset 2.000 s -> broken from 0:00:03.000 (2 shifts)"
        #expect(insert == Self.reply("calls[0] clip_ripple_insert: OK\n" + broken), "\(insert)")
        await studio.settle()
    }

    /// C6: a call that is not a step stops the batch before any step, and `record` shows no sheet.
    @Test func aRefusedCheckRunsNoStep() async throws {
        let package = try Self.package()
        let studio = try await package.open()
        var asked = 0
        let folder = try SocketFolder()
        let server = AgentServer(socket: folder.socket) {
            [
                AgentTarget(
                    studio: studio,
                    record: { _, _, _ in
                        asked += 1
                        return .busy(.task)
                    })
            ]
        }
        server.start()
        defer { server.stop() }
        let (before, revision) = (studio.session, studio.sessionRevision)

        let outcome = await batch(
            [Self.addT2, Self.call("record", ["seconds": 1.5, "arm": ["t1"], "playhead": 0])], to: folder.socket,
            package: package)

        let text = "record cannot run in a batch: a step is an edit of session.xml only."
        #expect(outcome == Self.refused(1, "record", text), "\(outcome)")
        #expect(asked == 0, "BATCH-S3-5 the consent sheet opened")
        #expect(studio.session == before && studio.sessionRevision == revision)
        await studio.settle()
    }

    /// C10: each busy cause refuses the batch with the text of the cause and no index. A studio
    /// that settles is busy too.
    @Test(arguments: [AgentBusy.task, .drag, .closing, .quit, .asking, .dialog, .export, .pendingTake])
    func eachBusyCauseRefusesTheBatch(cause: AgentBusy) async throws {
        let package = try Self.package()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio, busy: cause)
        defer { server.stop() }

        let outcome = await batch([Self.addT2], to: folder.socket, package: package)

        #expect(outcome == Self.reply(cause.message(package: package.path), isError: true), "BATCH-S3-6 \(outcome)")
        #expect(studio.session.track("T2") == nil && !studio.canUndo)
        await studio.settle()
    }

    @Test func aSettlingStudioRefusesTheBatch() async throws {
        let package = try Self.package()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let gate = Gate()
        let held = Task { await studio.serialized { await gate.wait() } }
        await until("the write turn is not held") { gate.waiting }
        let settled = Task { await studio.settle() }
        await until("settle did not start") { studio.settling }

        let outcome = await batch([Self.addT2], to: folder.socket, package: package)

        #expect(outcome == Self.reply(AgentBusy.task.message(package: package.path), isError: true), "\(outcome)")
        gate.open()
        await held.value
        await settled.value
        #expect(studio.session.track("T2") == nil)
    }

    /// C11: a later call sees the session that the calls before it made.
    @Test func aLaterCallSeesAnEarlierCall() async throws {
        let package = try Self.package()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let marker = { (name: String, extra: Call) in
            Self.call("marker_set", ["id": "M", "name": name].merging(extra) { $1 })
        }

        let pair = await batch([marker("A", ["at": 0]), marker("B", [:])], to: folder.socket, package: package)
        #expect(pair == Self.reply("calls[0] marker_set: M\ncalls[1] marker_set: M"), "BATCH-S3-7 \(pair)")
        #expect(studio.session.markers["M"]?.name == "B" && studio.session.markers["M"]?.position == 0)

        let cleared = await batch(
            [marker("C", ["at": 5, "image": ""]), marker("D", [:])], to: folder.socket, package: package)
        #expect(cleared == Self.reply("calls[0] marker_set: M\ncalls[1] marker_set: M"), "\(cleared)")
        #expect(studio.session.markers["M"]?.name == "D")

        let tracks = await batch(
            [Self.addT2, Self.call("track_rename", ["track": "T2", "name": "B"])], to: folder.socket,
            package: package)
        #expect(tracks == Self.reply("calls[0] track_add: T2\ncalls[1] track_rename: OK"), "\(tracks)")
        await studio.settle()
    }
}
