import DirigibleAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleMCP

/// `dirigible mcp` as the bridge to the app server (decision 0046, C2 and C8 of run
/// 2026-10-12-mcp-in-app): the binary reads `DIRIGIBLE_MCP_SOCKET`, connects, and forwards a call
/// to an `AgentServer` with a studio in this process.
@MainActor
struct BridgeCommandTests {
    @Test func forwardsThroughTheSocket() async throws {
        let package = try TemporaryPackage(try sessionWithHost())
        let studio = try await Studio.open(package.url)
        let folder = try #require(shortFolder())
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = AgentServer(socket: folder.appending(path: "mcp.sock")) { [AgentTarget(studio: studio)] }
        server.start()
        defer { server.stop() }

        let answers = try await mcp(
            [toolCall(1, "track_rename", ["package": package.url.path, "track": "t1", "name": "Guest"])],
            socket: folder.appending(path: "mcp.sock"))

        #expect(toolResult(answer(answers, id: 1)) == ("OK", false))
        #expect(studio.session.track("t1")?.name == "Guest")
        #expect(studio.canUndo, "the edit is one undo step in the studio")
        await studio.settle()
    }

    private func sessionWithHost() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        return session
    }

    /// A new folder under /tmp, short enough for a socket path.
    private func shortFolder() -> URL? {
        var template = Array("/tmp/dmcp-XXXXXX".utf8CString)
        return mkdtemp(&template).map { URL(filePath: String(cString: $0)) }
    }
}
