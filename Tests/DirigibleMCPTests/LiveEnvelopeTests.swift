import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `clip_envelope` and `clip_gain_range` on a package that the app has open (decision 0060, C6).
@MainActor
struct LiveEnvelopeTests {
    /// Each call is one edit with the agent name, and one undo gives back the session before it.
    @Test func eachEnvelopeCallIsOneUndoEntry() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
            try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 480_000), on: "t1")
        }
        for (tool, arguments) in [
            ("clip_envelope", ["clip": "A", "points": [[0, 0], [48_000, -16]]] as [String: any Sendable]),
            ("clip_gain_range", ["track": ["t1"], "from": 96_000, "to": 192_000, "db": -6]),
        ] {
            let (before, revision) = (studio.session, studio.sessionRevision)
            _ = await send(folder.socket, tool, arguments.merging(["package": package.path]) { $1 })
            let changed = studio.session.clip("A")?.clip.envelope != before.clip("A")?.clip.envelope
            #expect(changed, "\(tool) changed the envelope")
            #expect(studio.sessionRevision == revision + 1, "one \(tool) call is one edit")
            #expect(studio.undoAgent == AgentName(title: "Test Agent", clientName: nil))
            try studio.undo()
            let undone = studio.session == before
            #expect(undone, "one undo gives back the session before \(tool)")
            try studio.redo()
        }
        await studio.settle()
    }
}
