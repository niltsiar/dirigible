import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore
@testable import DirigibleMCP

/// A new folder under /tmp, short enough for a socket path (`sun_path` holds 104 bytes).
final class SocketFolder {
    let url: URL
    var socket: URL { url.appending(path: "mcp.sock") }

    init() throws {
        var template = Array("/tmp/dmcp-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw POSIXError(.EIO) }
        url = URL(filePath: String(cString: made))
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A package `Show.dirigible` with track `t1` "Host" and track `t2` "Music", in a new temporary
/// folder.
final class LivePackage {
    let folder: URL
    let url: URL
    var path: String { url.path }

    init(name: String = "Show") throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "DirigibleMCPTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appending(path: "\(name).dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Music", layout: .mono)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try session.write(to: url)
    }

    /// Adds a pending take that arms `t1`, with one 1 s segment. With `Clips/` at mode 0500 for
    /// the open, finalize fails, so the take stays pending (as `PendingTakeTests`).
    func addPendingTake(_ take: Int = 1, playhead: Frames = 0) throws {
        var session = try Session(contentsOf: url)
        try session.setRecording(
            Recording(take: take, playheadFrame: playhead, takeStartHostTimeNanos: takeStart, armedTracks: ["t1"]))
        try session.write(to: url)
        let capture = url.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        let header = CaptureHeader(
            deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelCount: 1, latency: 48, firstSampleTime: 512, firstHostTimeNanos: takeStart + 10_000_000)
        let writer = try SegmentWriter(
            folder: capture, name: SegmentName(take: take, arm: 1, segment: 1), header: header)
        for frame in [0, 47_999] {
            try writer.checkpoint(
                Checkpoint(
                    fileFrame: Int64(frame), sampleTime: 512 + Double(frame),
                    hostTimeNanos: takeStart + 10_000_000 + UInt64(frame) * 1_000_000_000 / 48_000))
        }
        let samples = [Float](repeating: 0.25, count: 48_000)
        try samples.withUnsafeBufferPointer { try writer.write($0, frames: 48_000) }
        try writer.close()
    }

    /// Opens a studio. With a pending take, `Clips/` is read-only during the open, and the studio
    /// must have that take pending.
    @MainActor
    func open(pending take: Int? = nil) async throws -> Studio {
        guard let take else { return try await Studio.open(url) }
        let clips = url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        chmod(clips.path, 0o500)
        defer { chmod(clips.path, 0o755) }
        let studio = try await Studio.open(url)
        try #require(studio.pendingTake?.take == take)
        return studio
    }

    deinit { try? FileManager.default.removeItem(at: folder) }
}

let takeStart: UInt64 = 1_000_000_000_000

/// The agent of the test calls.
let testClient = ClientInfo(title: "Test Agent", name: "test-agent")

/// Sends one call over `socket` from a new bridge, off the main actor, so the server can answer.
/// The reply waits for the main actor of a test shard, and other suites hold it for over 30 s, so
/// the bridge of the tests waits 120 s. This is test patience, not a product time.
func send(_ socket: URL, _ tool: String, _ arguments: [String: any Sendable], client: ClientInfo = testClient) async
    -> AgentBridge.Outcome
{
    await onThread {
        AgentBridge(socket: socket, timeout: .seconds(120)).call(tool: tool, arguments: arguments, client: client)
    }
}

/// Runs a blocking `body` on a new thread, not on the concurrency pool: a bridge call blocks its
/// thread, and the server needs a pool thread for its hop to the main actor.
func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in Thread.detachNewThread { continuation.resume(returning: body()) } }
}

/// Waits until `condition` holds, or records an issue after `limit`. The limit is 60 s: other
/// suites of a test shard hold the main actor for over 30 s (test patience, not a product time).
@MainActor
func until(limit: Duration = .seconds(60), _ message: String, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("\(message) after \(limit)")
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// A server for one studio, on a new socket.
@MainActor
func liveServer(
    _ studio: Studio, busy: AgentBusy? = nil, sheetCause: @escaping @MainActor () -> AgentBusy? = { nil }
) throws -> (AgentServer, SocketFolder) {
    let folder = try SocketFolder()
    let server = AgentServer(socket: folder.socket) {
        [AgentTarget(studio: studio, busy: busy, sheetCause: sheetCause)]
    }
    server.start()
    #expect(server.state == .listening)
    return (server, folder)
}

/// A gate that holds an async task until `open()`. `waiting` is true once a task waits.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiting: Bool { lock.withLock { !waiters.isEmpty } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let resumed = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in resumed { waiter.resume() }
    }
}

/// A modern `tools/call` line with the client of the test calls in its `_meta`.
func callLine(_ tool: String, _ arguments: [String: Any], id: Int = 1, client: ClientInfo = testClient) -> String {
    MCPServer.encode([
        "jsonrpc": "2.0", "id": id, "method": "tools/call",
        "params": [
            "name": tool, "arguments": arguments,
            "_meta": [
                "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                "io.modelcontextprotocol/clientInfo": ["name": client.name ?? "", "title": client.title ?? ""],
            ],
        ],
    ])
}

/// The one text item of a tool result answer line and its `isError`.
func toolText(_ answer: String?) -> (text: String, isError: Bool) {
    let object = answer.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
    let result = object?["result"] as? [String: Any]
    let content = result?["content"] as? [[String: Any]]
    return (content?.first?["text"] as? String ?? "", result?["isError"] as? Bool ?? true)
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

    /// Ends the write side: the server reads EOF, and the client can still read.
    func shutdownWrite() { shutdown(fd, SHUT_WR) }

    /// One reply line, or nil when none comes within 5 s.
    func readLine() -> String? {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&entry, 1, 5_000) == 1, read(fd, &byte, 1) == 1 else { return nil }
            if byte == UInt8(ascii: "\n") { return String(decoding: buffer, as: UTF8.self) }
            buffer.append(byte)
        }
    }

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
