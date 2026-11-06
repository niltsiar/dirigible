import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `clip_close_gaps`, `clip_roll`, and `clip_slip` on a package that the app has open.
@MainActor
struct TimelineEditToolTests {
    /// Each call is one edit with the agent name, and one undo gives back the session before the
    /// call. A refusal is an error and no edit.
    @Test func eachTimelineEditToolIsOneUndoEntry() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
            for (id, start) in [("A", 0), ("B", 48_000), ("C", 120_000)] {
                try session.place(
                    Clip(id: ClipID(id), file: "f", start: Frames(start), offset: Frames(start), length: 48_000),
                    on: "t1")
            }
        }
        let calls: [(tool: String, arguments: [String: any Sendable], reply: String)] = [
            ("clip_close_gaps", ["clips": ["A", "C"]], "C"),
            ("clip_roll", ["clip": "A", "by": 1000], "OK"),
            ("clip_slip", ["clips": ["B"], "by": -500], "OK"),
        ]
        for call in calls {
            let (before, revision) = (studio.session, studio.sessionRevision)
            let outcome = await send(folder.socket, call.tool, call.arguments.merging(["package": package.path]) { $1 })
            #expect(replyText(outcome) == call.reply, "\(call.tool)")
            #expect(studio.session != before, "\(call.tool) changed nothing")
            #expect(studio.sessionRevision == revision + 1, "\(call.tool): one call is one edit")
            #expect(studio.undoAgent == AgentName(title: "Test Agent", clientName: nil))
            try studio.undo()
            let undone = studio.session == before
            #expect(undone, "\(call.tool): one undo gives back the session before the call")
            try studio.redo()
        }
        let settled = studio.sessionRevision
        let refused = await send(folder.socket, "clip_roll", ["package": package.path, "clip": "C", "by": 1])
        #expect(
            refused
                == .reply(
                    .result(text: "no clip touches the end of clip \"C\", so it has no join to roll.", isError: true)))
        #expect(studio.sessionRevision == settled, "an error is no edit")
        await studio.settle()
    }
}
