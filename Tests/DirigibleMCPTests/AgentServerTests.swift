import DirigibleCore
import Foundation
import Testing

@testable import DirigibleMCP

/// The life cycle of the app server (decision 0046, criteria C1, C9, C10, and C16 of run
/// 2026-10-12-mcp-in-app).
@MainActor
struct AgentServerTests {
    /// A server with no window: each call gets "not open".
    func emptyServer(_ socket: URL) -> AgentServer {
        AgentServer(socket: socket) { [] }
    }

    /// A call for a package that no window has.
    func probe(_ socket: URL) async -> AgentBridge.Outcome {
        await send(socket, "session_info", ["package": "/tmp/none.dirigible"])
    }

    /// C1: on, the socket has mode 0600 in a folder with mode 0700, and the agent counts; off, the
    /// file goes, the connection gets EOF, and the lock is free for the next start.
    @Test func startAndStop() async throws {
        let folder = try SocketFolder()
        let socket = folder.url.appending(path: "Dirigible/mcp.sock")
        let server = emptyServer(socket)
        server.start()
        #expect(server.state == .listening)
        #expect(mode(of: socket.path) == 0o600)
        #expect(mode(of: socket.deletingLastPathComponent().path) == 0o700)

        let client = try #require(Client(socket))
        await until("the server did not count the agent") { server.connected == 1 }
        server.stop()
        #expect(server.state == .off)
        await until("the socket file stays") { !FileManager.default.fileExists(atPath: socket.path) }
        #expect(await onThread { client.readsEOF() }, "the connection did not close")
        let afterStop = await probe(socket)
        #expect(afterStop == .noApp)
        await until("the stop did not free the lock") { !server.draining }

        let next = emptyServer(socket)
        next.start()
        #expect(next.state == .listening, "the lock stays held")
        next.stop()
    }

    /// C9: a socket file of a process that ended is replaced at start.
    @Test func staleSocketIsReplaced() async throws {
        let folder = try SocketFolder()
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(withAddress(folder.socket.path) { bind(stale, $0, $1) } == 0)
        close(stale)
        #expect(FileManager.default.fileExists(atPath: folder.socket.path))

        let server = emptyServer(folder.socket)
        server.start()
        defer { server.stop() }

        #expect(server.state == .listening)
        let outcome = await probe(folder.socket)
        #expect(outcome == .reply(.notOpen))
    }

    /// C1: a start at once after a stop serves: the switch off and on, and a cancelled Quit. The
    /// start opens when the stop freed the lock.
    @Test func stopThenStartServes() async throws {
        let folder = try SocketFolder()
        let server = emptyServer(folder.socket)
        server.start()
        server.stop()
        server.start()
        defer { server.stop() }

        await until("C1: a start after a stop does not listen") { server.state == .listening }
        #expect(await probe(folder.socket) == .reply(.notOpen))
    }

    /// C12: many short connections end with the count 0, so the agent mark hides. The counts go
    /// to the main actor in their order.
    @Test func lastCountWins() async throws {
        let folder = try SocketFolder()
        let server = emptyServer(folder.socket)
        server.start()
        defer { server.stop() }
        let socket = folder.socket
        await onThread {
            for _ in 0..<100 { Client(socket)?.close() }
        }
        await until("the closed connections stay counted") { server.connected == 0 }
        // More main-actor turns: a late count of 1 would show here.
        for _ in 0..<20 { await Task.yield() }
        #expect(server.connected == 0)
    }

    /// C9: with the lock held by another server, a second server does not listen, and the first
    /// one goes on.
    @Test func secondServerDoesNotListen() async throws {
        let folder = try SocketFolder()
        let first = emptyServer(folder.socket)
        first.start()
        defer { first.stop() }
        let second = emptyServer(folder.socket)
        second.start()

        #expect(second.state == .servedElsewhere)
        let outcome = await probe(folder.socket)
        #expect(outcome == .reply(.notOpen))
    }

    /// C10: `sun_path` holds 104 bytes with the NUL: a path of 103 bytes binds, and one of 104
    /// bytes gives `failed` and makes no file.
    @Test func pathLimit() async throws {
        let folder = try SocketFolder()
        func path(bytes: Int) -> URL {
            let prefix = folder.url.path + "/"
            return URL(filePath: prefix + String(repeating: "s", count: bytes - prefix.utf8.count))
        }
        let fits = emptyServer(path(bytes: 103))
        fits.start()
        #expect(fits.state == .listening)
        #expect(FileManager.default.fileExists(atPath: path(bytes: 103).path))
        fits.stop()

        let long = emptyServer(path(bytes: 104))
        long.start()
        #expect(long.state == .failed)
        #expect(!FileManager.default.fileExists(atPath: path(bytes: 104).path))
    }

    /// C8: the app and the bridge read the socket path from `DIRIGIBLE_MCP_SOCKET` when it is set.
    @Test func socketPathFromEnvironment() {
        #expect(
            agentSocketPath(environment: ["DIRIGIBLE_MCP_SOCKET": "/tmp/dmcp-verify/mcp.sock"]).path
                == "/tmp/dmcp-verify/mcp.sock")
        #expect(agentSocketPath(environment: [:]).path.hasSuffix("/Library/Application Support/Dirigible/mcp.sock"))
        #expect(agentSocketPath(environment: ["DIRIGIBLE_MCP_SOCKET": ""]).lastPathComponent == "mcp.sock")
    }

    /// C16: each accepted connection has SO_NOSIGPIPE, so a write to a bridge that closed gives
    /// EPIPE and no signal. The SIGPIPE guard of `start()` hides a missing flag from the other tests.
    @Test func acceptedConnectionHasNoSigPipe() async throws {
        let folder = try SocketFolder()
        let server = emptyServer(folder.socket)
        server.start()
        defer { server.stop() }
        let client = try #require(Client(folder.socket))
        await until("the server did not count the agent") { server.connected == 1 }

        let fds = server.listener?.connectionFDs ?? []
        #expect(fds.count == 1)
        for fd in fds {
            var on: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            #expect(getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, &size) == 0)
            #expect(on != 0, "C16: an accepted connection has no SO_NOSIGPIPE")
        }
        client.close()
    }

    /// C16: a bridge that sends and closes before the accept leaves a socket that refuses
    /// SO_NOSIGPIPE (EINVAL: both directions are shut). The reply write to it must not raise
    /// SIGPIPE. The test opens the listener alone, so no SIGPIPE guard of `start()` hides it.
    @Test func peerClosedBeforeAcceptGetsNoSignal() async throws {
        let folder = try SocketFolder()
        var listener: AgentListener?
        if case .listening(let opened) = AgentListener.open(
            socket: folder.socket, handle: { _ in .notOpen }, counted: { _ in })
        {
            listener = opened
        }
        try #require(listener != nil)
        defer { listener?.stop() }

        // Many short connections: the listener accepts most of them after their close.
        let socket = folder.socket
        await onThread {
            for _ in 0..<200 {
                guard let client = Client(socket) else { continue }
                client.send(#"{"tool":"session_info","arguments":{"package":"/tmp/none.dirigible"}}"#)
                client.close()
            }
        }
        #expect(await probe(folder.socket) == .reply(.notOpen), "the listener stops answering")
    }

    /// C5: a reply larger than the socket buffer (8 KB on Darwin) arrives whole. An accepted fd
    /// takes O_NONBLOCK from the listener, so a write there can give EAGAIN.
    @Test func largeReplyArrivesWhole() async throws {
        let folder = try SocketFolder()
        let text = String(repeating: "0123456789", count: 10_000)
        var listener: AgentListener?
        if case .listening(let opened) = AgentListener.open(
            socket: folder.socket, handle: { _ in .result(text: text, isError: false) }, counted: { _ in })
        {
            listener = opened
        }
        try #require(listener != nil)
        defer { listener?.stop() }

        #expect(
            await probe(folder.socket) == .reply(.result(text: text, isError: false)), "C5: the large reply is lost")
    }

    /// Decision 0046 Owners: the main actor never waits for the queue. A stop while a reply
    /// write waits for a peer that reads nothing returns at once.
    @Test func stopDuringAStalledWriteReturnsAtOnce() async throws {
        let folder = try SocketFolder()
        let text = String(repeating: "0123456789", count: 100_000)
        var listener: AgentListener?
        if case .listening(let opened) = AgentListener.open(
            socket: folder.socket, handle: { _ in .result(text: text, isError: false) }, counted: { _ in })
        {
            listener = opened
        }
        try #require(listener != nil)
        let client = try #require(Client(folder.socket))
        client.send(#"{"tool":"session_info","arguments":{"package":"/tmp/none.dirigible"}}"#)
        await until("the reply write did not start") { client.hasData }

        let start = ContinuousClock.now
        listener?.stop()
        let waited = ContinuousClock.now - start
        // The close lets the write fail now, so the shared queue is free for the next test.
        client.close()
        #expect(waited < .milliseconds(500), "the main actor waited \(waited) for the queue")
    }

    /// C1: a stop during a call answers that call, then closes the connection and frees the lock,
    /// also when the app drops the listener at once (decision 0046 Life cycle).
    @Test func stopAnswersTheRunningCall() async throws {
        let folder = try SocketFolder()
        let gate = Gate()
        var listener: AgentListener?
        let handle: @Sendable (AgentCall) async -> AgentReply = { _ in
            await gate.wait()
            return .notOpen
        }
        if case .listening(let opened) = AgentListener.open(socket: folder.socket, handle: handle, counted: { _ in }) {
            listener = opened
        }
        try #require(listener != nil)
        let reply = Task { await send(folder.socket, "session_info", ["package": "/tmp/none.dirigible"]) }
        await until("the call did not start") { gate.waiting }
        listener?.stop()
        listener = nil
        gate.open()

        #expect(await reply.value == .reply(.notOpen), "C1: the running call got no reply")
        let next = emptyServer(folder.socket)
        next.start()
        #expect(next.state == .listening, "the lock stays held")
        next.stop()
    }

    /// C16: a bridge that closes before its reply does not stop the server: the next connection
    /// is served.
    @Test func peerClosesBeforeReply() async throws {
        let folder = try SocketFolder()
        let server = emptyServer(folder.socket)
        server.start()
        defer { server.stop() }

        // The main actor sends and closes before the server can answer on it.
        let client = try #require(Client(folder.socket))
        client.send(#"{"tool":"session_info","arguments":{"package":"/tmp/none.dirigible"}}"#)
        client.close()

        let outcome = await probe(folder.socket)
        #expect(outcome == .reply(.notOpen))
        await until("the closed connection stays counted") { server.connected == 0 }
    }
}

/// The permission bits of a path.
func mode(of path: String) -> mode_t {
    var info = stat()
    return stat(path, &info) == 0 ? info.st_mode & 0o777 : 0
}

/// A raw client of the app socket.
final class Client: @unchecked Sendable {
    private var fd: Int32

    init?(_ socket: URL) {
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        setNoSigPipe(fd)
        guard withAddress(socket.path, { connect(fd, $0, $1) }) == 0 else {
            Darwin.close(fd)
            fd = -1
            return nil
        }
    }

    func send(_ line: String) { _ = writeAll(fd, Data((line + "\n").utf8)) }

    /// True when bytes wait to be read now.
    var hasData: Bool {
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&entry, 1, 0) == 1
    }

    /// True when a read gets EOF within 5 s.
    func readsEOF() -> Bool {
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&entry, 1, 5_000) == 1 else { return false }
        var byte: UInt8 = 0
        return read(fd, &byte, 1) == 0
    }

    func close() {
        Darwin.close(fd)
        fd = -1
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }
}
