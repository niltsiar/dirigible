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
        #expect(await probe(socket) == .noApp)

        let next = emptyServer(socket)
        await until("the lock stays held") {
            next.start()
            return next.state == .listening
        }
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
        #expect(await probe(folder.socket) == .reply(.notOpen))
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
        #expect(await probe(folder.socket) == .reply(.notOpen))
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

    /// C16: a bridge that closes before its reply does not stop the server: the next connection
    /// is served. The server ignores SIGPIPE, so this test does not check SO_NOSIGPIPE.
    @Test func peerClosesBeforeReply() async throws {
        let folder = try SocketFolder()
        let server = emptyServer(folder.socket)
        server.start()
        defer { server.stop() }

        // The main actor sends and closes before the server can answer on it.
        let client = try #require(Client(folder.socket))
        client.send(#"{"tool":"session_info","arguments":{"package":"/tmp/none.dirigible"}}"#)
        client.close()

        #expect(await probe(folder.socket) == .reply(.notOpen))
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
