import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `clip_heal` on a package that the app has open (C29 of run 2026-10-17-agent-pack).
@MainActor
struct LiveHealTests {
    /// Three pieces of one clip heal in one call: one edit with the agent name, and one undo gives
    /// back the session before the call. A call with no join to heal is an error and no edit.
    @Test func aLiveHealIsOneUndoEntry() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
            try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 480_000), on: "t1")
            try session.splitClips(at: [100_000, 300_000], on: ["t1"])
        }
        let (before, revision) = (studio.session, studio.sessionRevision)
        #expect(before.track("t1")?.clips.count == 3)

        let outcome = await send(folder.socket, "clip_heal", ["package": package.path])

        #expect(replyText(outcome) == "A")
        #expect(studio.session.track("t1")?.clips.map(\.length) == [480_000])
        #expect(studio.sessionRevision == revision + 1, "one call is one edit")
        #expect(studio.undoAgent == AgentName(title: "Test Agent", clientName: nil))
        try studio.undo()
        let undone = studio.session == before
        #expect(undone, "one undo gives back the three pieces")

        try studio.redo()
        let healed = studio.sessionRevision
        let refused = await send(folder.socket, "clip_heal", ["package": package.path])
        #expect(refused == .reply(.result(text: "no join to heal.", isError: true)))
        #expect(studio.sessionRevision == healed, "an error is no edit")
        await studio.settle()
    }
}
