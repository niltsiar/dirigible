import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleMCP

/// The `dirigible mcp` bridge against a fake app (decision 0046, criteria C6 and C8 of run
/// 2026-10-12-mcp-in-app). Each test drives `MCPServer` with the route of an `AgentBridge`.
struct BridgeTests {
    /// C8: the bridge forwards a call with the agent name: the request `_meta` in the modern
    /// era, and the `clientInfo` of `initialize` in the legacy era.
    @Test func forwardsWithTheAgentName() throws {
        let app = try FakeApp { _ in .reply(#"{"isError":false,"text":"from the app"}"#) }
        var modern = MCPServer(route: AgentBridge(socket: app.socket).route)
        let answer = modern.answer(callLine("track_rename", ["package": "/x.dirigible", "track": "t1", "name": "A"]))
        #expect(toolText(answer) == ("from the app", false))

        var legacy = MCPServer(route: AgentBridge(socket: app.socket).route)
        _ = legacy.answer(
            MCPServer.encode([
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["protocolVersion": "2025-11-25", "clientInfo": ["name": "codex-mcp-client"]],
            ]))
        _ = legacy.answer(
            MCPServer.encode([
                "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": ["name": "session_info", "arguments": ["package": "/x.dirigible"]],
            ]))

        let calls = app.calls
        try #require(calls.count == 2)
        #expect(calls[0]["tool"] as? String == "track_rename")
        #expect((calls[0]["arguments"] as? [String: Any])?["name"] as? String == "A")
        #expect((calls[0]["client"] as? [String: Any])?["title"] as? String == "Test Agent")
        #expect((calls[1]["client"] as? [String: Any])?["name"] as? String == "codex-mcp-client")
    }

    /// W3: `devices` and `apps` read this Mac in the server and never go to the app. The control:
    /// a `session_info` call of the same server reaches the fake app.
    @Test func aSourceToolNeverReachesTheApp() throws {
        let app = try FakeApp { _ in .reply(#"{"isError":false,"text":"from the app"}"#) }
        var server = MCPServer(route: AgentBridge(socket: app.socket).route)

        for tool in ["devices", "apps"] {
            let (text, isError) = toolText(server.answer(callLine(tool, [:])))
            #expect(!isError && text != "from the app", "\(tool): \(text)")
        }
        #expect(app.calls.isEmpty, "\(app.calls)")
        #expect(
            toolText(server.answer(callLine("session_info", ["package": "/x.dirigible"]))) == ("from the app", false))
        #expect(app.calls.count == 1)
    }

    /// C6: a package that no window has runs on the files: `session_create` makes it.
    @Test func notOpenRunsOnFiles() throws {
        let app = try FakeApp { _ in .reply(#"{"notOpen":true}"#) }
        let package = try LivePackage()
        let target = package.folder.appending(path: "New.dirigible").path
        var server = MCPServer(route: AgentBridge(socket: app.socket).route)

        let answer = server.answer(callLine("session_create", ["package": target, "sample_rate": 48_000]))

        #expect(toolText(answer) == ("OK", false))
        #expect(FileManager.default.fileExists(atPath: target + "/session.xml"))
        #expect(app.calls.count == 1)
    }

    /// C8: with no app socket, the call runs on the files, as before decision 0046.
    @Test func noSocketRunsOnFiles() throws {
        let folder = try SocketFolder()
        let package = try LivePackage()
        var server = MCPServer(route: AgentBridge(socket: folder.socket).route)

        let answer = server.answer(
            callLine("track_rename", ["package": package.path, "track": "t1", "name": "Guest"]))

        #expect(toolText(answer) == ("OK", false))
        #expect(try Session(contentsOf: package.url).track("t1")?.name == "Guest")
    }

    /// C8: a connection that closes after the send gives the lost-call error, and the bridge never
    /// runs the call on the files.
    @Test func closedDuringACallIsLost() throws {
        let app = try FakeApp { _ in .close }
        let package = try LivePackage()
        let target = package.folder.appending(path: "New.dirigible").path
        var server = MCPServer(route: AgentBridge(socket: app.socket).route)

        let answer = server.answer(callLine("session_create", ["package": target, "sample_rate": 48_000]))

        #expect(toolText(answer) == (lostCallMessage, true))
        #expect(!FileManager.default.fileExists(atPath: target), "the bridge ran the call again")
    }

    /// C8: at the time limit the bridge closes the connection, so the late reply of the first call
    /// never answers the second call.
    @Test func timeoutThenNextCall() throws {
        let app = try FakeApp { count in
            count == 1 ? .lateReply(#"{"isError":false,"text":"late"}"#) : .reply(#"{"isError":false,"text":"second"}"#)
        }
        var server = MCPServer(route: AgentBridge(socket: app.socket, timeout: .milliseconds(300)).route)
        let arguments = ["package": "/x.dirigible", "track": "t1", "name": "A"]

        let first = server.answer(callLine("track_rename", arguments, id: 1))
        let second = server.answer(callLine("track_rename", arguments, id: 2))

        #expect(toolText(first) == (lostCallMessage, true))
        #expect(toolText(second) == ("second", false))
        #expect(app.connections == 2, "the second call connects again")
    }

    /// Decision 0048: during a call, a cancel of the running request or the end of stdin closes
    /// the connection, so the app ends a record request. A cancel of another request does not. A
    /// cancelled call gets no answer (decision 0049).
    @Test(arguments: ["cancel", "eof", "other"]) func stdinDuringACall(_ how: String) throws {
        let app = try FakeApp { _ in how == "other" ? .lateReply(#"{"isError":false,"text":"late"}"#) : .hold }
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        let (readFD, writeFD) = (fds[0], fds[1])
        defer { close(readFD) }
        let socket = app.socket
        // writeAll uses send(2), which a pipe refuses.
        let put = { (line: String) in
            _ = Array((line + "\n").utf8).withUnsafeBytes { write(writeFD, $0.baseAddress, $0.count) }
        }
        put(callLine("record", ["package": "/x.dirigible"], id: 7))
        let answer = OSAllocatedUnfairLock<String?>(initialState: nil)
        let done = OSAllocatedUnfairLock(initialState: false)
        Thread.detachNewThread {
            let input = LineInput(fd: readFD)
            var server = MCPServer(route: AgentBridge(socket: socket, input: input).route, pollCancel: input.pollCancel)
            let reply = input.next().flatMap { server.answer($0) }
            answer.withLock { $0 = reply }
            done.withLock { $0 = true }
        }
        try #require(waitUntil(5) { app.calls.count == 1 }, "the call did not reach the app")

        if how == "eof" {
            close(writeFD)
        } else {
            let id = how == "cancel" ? 7 : 99
            let cancel = MCPServer.encode([
                "jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": id],
            ])
            put(cancel)
        }

        try #require(waitUntil(10) { done.withLock { $0 } }, "the bridge still waits")
        if how != "eof" { close(writeFD) }
        let reply = answer.withLock { $0 }
        switch how {
        case "other": #expect(toolText(reply) == ("late", false), "a cancel of another request ended the call")
        case "cancel": #expect(reply == nil, "a cancelled call got an answer: \(reply ?? "")")
        default: #expect(toolText(reply) == (lostCallMessage, true))
        }
        if how != "other" { #expect(waitUntil(5) { app.holdsClosed == 1 }, "the app did not see the close") }
    }

    /// C8: an app that closed between two calls counts as no app: the second call runs on the
    /// files.
    @Test func listenerClosedBetweenCalls() throws {
        let app = try FakeApp { _ in .replyAndQuit(#"{"isError":false,"text":"first"}"#) }
        let package = try LivePackage()
        var server = MCPServer(route: AgentBridge(socket: app.socket).route)
        let arguments = ["package": package.path, "track": "t1", "name": "Guest"]

        let first = server.answer(callLine("track_rename", arguments, id: 1))
        app.waitForQuit()
        let second = server.answer(callLine("track_rename", arguments, id: 2))

        #expect(toolText(first) == ("first", false))
        #expect(toolText(second) == ("OK", false))
        #expect(try Session(contentsOf: package.url).track("t1")?.name == "Guest")
    }
}

/// A fake app socket on its own thread. For each call line, `answer` gets the call number (from
/// 1) and gives the action.
final class FakeApp: @unchecked Sendable {
    enum Action {
        case reply(String)
        /// Close the connection with no reply.
        case close
        /// Reply after 1 s.
        case lateReply(String)
        /// Reply, then close the connection and the listener.
        case replyAndQuit(String)
        /// No reply: read until the bridge closes the connection, and count the close.
        case hold
        /// Each line after its wait in seconds, each in one write.
        case script([(TimeInterval, String)])
    }

    let socket: URL
    private let folder: SocketFolder
    private let listenFD: Int32
    private let lock = NSLock()
    private var received: [[String: Any]] = []
    private var accepted = 0
    private var stopping = false
    private let quit = DispatchSemaphore(value: 0)

    var calls: [[String: Any]] { lock.withLock { received } }
    var connections: Int { lock.withLock { accepted } }
    var holdsClosed: Int { lock.withLock { closedHolds } }
    private var closedHolds = 0

    init(answer: @escaping @Sendable (Int) -> Action) throws {
        folder = try SocketFolder()
        socket = folder.socket
        listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard withAddress(socket.path, { bind(listenFD, $0, $1) }) == 0, listen(listenFD, 4) == 0 else {
            throw POSIXError(.EADDRINUSE)
        }
        // The accept thread polls, so it ends when the test drops the fake or `replyAndQuit` stops
        // it; then it closes the listener itself, so no thread uses a closed fd.
        Thread.detachNewThread { [weak self, listenFD] in
            while true {
                var entry = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
                let ready = poll(&entry, 1, 50)
                guard let app = self, !app.lock.withLock({ app.stopping }) else { break }
                guard ready > 0 else { continue }
                let fd = accept(listenFD, nil, nil)
                guard fd >= 0 else { continue }
                setNoSigPipe(fd)
                app.lock.withLock { app.accepted += 1 }
                Thread.detachNewThread { app.talk(fd, answer) }
            }
            close(listenFD)
        }
    }

    func waitForQuit() { quit.wait() }

    /// Serves one connection on its own thread.
    private func talk(_ fd: Int32, _ answer: @Sendable (Int) -> Action) {
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        connection: while true {
            let count = read(fd, &bytes, bytes.count)
            guard count > 0 else { break }
            buffer.append(contentsOf: bytes[..<count])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let call = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                let number = lock.withLock {
                    received.append(call)
                    return received.count
                }
                switch answer(number) {
                case .reply(let reply): _ = writeAll(fd, Data((reply + "\n").utf8))
                case .close: break connection
                case .hold:
                    while read(fd, &bytes, bytes.count) > 0 {}
                    lock.withLock { closedHolds += 1 }
                    break connection
                case .script(let lines):
                    for (wait, line) in lines {
                        Thread.sleep(forTimeInterval: wait)
                        _ = writeAll(fd, Data((line + "\n").utf8))
                    }
                case .lateReply(let reply):
                    Thread.sleep(forTimeInterval: 1)
                    _ = writeAll(fd, Data((reply + "\n").utf8))
                case .replyAndQuit(let reply):
                    _ = writeAll(fd, Data((reply + "\n").utf8))
                    close(fd)
                    lock.withLock { stopping = true }
                    unlink(socket.path)
                    quit.signal()
                    return
                }
            }
        }
        close(fd)
    }

}

/// Polls `condition` for up to `seconds` on the test thread.
func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let end = Date() + seconds
    while !condition() {
        guard Date() < end else { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return true
}
