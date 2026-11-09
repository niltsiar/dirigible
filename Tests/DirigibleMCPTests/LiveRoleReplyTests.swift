import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// C8 of run 2026-11-08-role-explain: the reply of `track_role` on an open session holds `OK`
/// and the line that says the role changes no sound. Each call goes over a real socket.
@MainActor
struct LiveRoleReplyTests {
    @Test func theReplyHoldsTheRoleLine() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await send(
            folder.socket, "track_role", ["package": package.path, "track": "t1", "role": "music"])

        #expect(outcome == .reply(.result(text: "OK\n" + EditRules.roleReply, isError: false)), "\(outcome)")
        #expect(studio.session.track("t1")?.role == .music)
        await studio.settle()
    }
}
