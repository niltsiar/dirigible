import Foundation
import Testing
import os

@testable import DirigibleMCP

/// The frames of a long call and their failures (code gate 1 of run 7b, items 2 and 8).
@MainActor
struct BridgeKeepAliveTests {
    let rename = ["package": "/x.dirigible", "track": "t1", "name": "A"]

    func listener(keepAlive: Duration = .seconds(10), _ handle: @escaping AgentListener.Handle) throws -> (
        AgentListener, SocketFolder
    ) {
        let folder = try SocketFolder()
        let opening = AgentListener.open(socket: folder.socket, handle: handle, counted: { _ in }, keepAlive: keepAlive)
        guard case .listening(let listener) = opening else { throw POSIXError(.EADDRINUSE) }
        return (listener, folder)
    }

    /// Item 2: a job that reports no new value still sends a frame in each keep-alive time, so the
    /// bridge limit does not end it. A repeated value sends no second notification to the client.
    /// The bridge limit is more than the 5 s write limit: a stalled write of another suite can hold
    /// the shared listener queue for that time.
    @Test func aSilentJobKeepsTheCallOpen() async throws {
        let (listener, folder) = try listener(keepAlive: .milliseconds(300)) { _, _ in
            try? await Task.sleep(for: .seconds(8))
            return .result(text: "done", isError: false)
        }
        defer { listener.stop() }
        let (sent, socket) = (Sent(), folder.socket)
        let answer = await onThread {
            var server = MCPServer(route: AgentBridge(socket: socket, timeout: .seconds(7)).route, send: sent.send)
            return server.answer(progressCall("loudness", ["package": "/x.dirigible"]))
        }
        #expect(toolText(answer) == ("done", false), "the bridge lost a call whose job is silent")
        #expect(sent.progress(token: 1).count <= 1, "a repeated value went to the client: \(sent.progress(token: 1))")
    }

    /// Code gate 2 item 1: a short call sends no keep-alive frame, so a stalled app still gives
    /// the lost-call text at the bridge limit.
    @Test func aShortCallIsLostAtTheBridgeLimit() async throws {
        let (listener, folder) = try listener(keepAlive: .milliseconds(300)) { _, _ in
            try? await Task.sleep(for: .seconds(3))
            return .result(text: "done", isError: false)
        }
        defer { listener.stop() }
        let (socket, rename) = (folder.socket, rename)
        let answer = await onThread {
            var server = MCPServer(route: AgentBridge(socket: socket, timeout: .seconds(1)).route)
            return server.answer(progressCall("track_rename", rename))
        }
        #expect(toolText(answer) == (lostCallMessage, true), "a short call got keep-alive frames")
    }

    /// Item 2: a lost `export` or `render` tells the agent to check the output file.
    @Test(arguments: ["export", "render"])
    func aLostExportNamesTheOutputFile(tool: String) async throws {
        let app = try FakeApp { _ in .script([(3, #"{"isError":false,"text":"late"}"#)]) }
        let socket = app.socket
        let answer = await onThread {
            var server = MCPServer(route: AgentBridge(socket: socket, timeout: .seconds(1)).route)
            return server.answer(progressCall(tool, ["package": "/x.dirigible", "out": "/tmp/x.wav"]))
        }
        let text =
            "The connection to Dirigible closed during the call. The \(tool) can still write its file: check the "
            + "output file, and read the session before you try again."
        #expect(toolText(answer) == (text, true))
    }

    /// Item 8: a frame that the listener cannot write ends the connection and cancels its call.
    /// The client reads nothing, so the keep-alive frames of the long call fill the socket buffer.
    @Test func aFailedFrameWriteEndsTheConnection() async throws {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let (listener, folder) = try listener(keepAlive: .milliseconds(1)) { _, report in
            report(0.5)
            try? await Task.sleep(for: .seconds(120))
            cancelled.withLock { $0 = Task.isCancelled }
            return .result(text: "late", isError: false)
        }
        defer { listener.stop() }
        let client = try #require(Client(folder.socket))
        client.send(
            MCPServer.encode([
                "tool": "loudness", "arguments": ["package": "/x.dirigible"], "client": [String: String](),
            ]))

        await until("the failed frame write did not end the call") { cancelled.withLock { $0 } }
        withExtendedLifetime(client) {}
    }
}
