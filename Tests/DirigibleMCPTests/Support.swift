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

    /// Adds a pending take 1 that arms `t1`, with one 1 s segment. With `Clips/` at mode 0500 for
    /// the open, finalize fails, so the take stays pending (as `PendingTakeTests`).
    func addPendingTake() throws {
        var session = try Session(contentsOf: url)
        try session.setRecording(
            Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: takeStart, armedTracks: ["t1"]))
        try session.write(to: url)
        let capture = url.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        let header = CaptureHeader(
            deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelCount: 1, latency: 48, firstSampleTime: 512, firstHostTimeNanos: takeStart + 10_000_000)
        let writer = try SegmentWriter(folder: capture, name: SegmentName(take: 1, arm: 1, segment: 1), header: header)
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

    /// Opens a studio. With a pending take, `Clips/` is read-only during the open.
    @MainActor
    func open(pending: Bool = false) async throws -> Studio {
        guard pending else { return try await Studio.open(url) }
        let clips = url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        chmod(clips.path, 0o500)
        defer { chmod(clips.path, 0o755) }
        let studio = try await Studio.open(url)
        try #require(studio.pendingTake?.take == 1)
        return studio
    }

    deinit { try? FileManager.default.removeItem(at: folder) }
}

let takeStart: UInt64 = 1_000_000_000_000

/// The agent of the test calls.
let testClient = ClientInfo(title: "Test Agent", name: "test-agent")

/// Sends one call over `socket` from a new bridge, off the main actor, so the server can answer.
func send(_ socket: URL, _ tool: String, _ arguments: [String: any Sendable], client: ClientInfo = testClient) async
    -> AgentBridge.Outcome
{
    await onThread { AgentBridge(socket: socket).call(tool: tool, arguments: arguments, client: client) }
}

/// Runs a blocking `body` on a new thread, not on the concurrency pool: a bridge call blocks its
/// thread, and the server needs a pool thread for its hop to the main actor.
func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in Thread.detachNewThread { continuation.resume(returning: body()) } }
}

/// Waits until `condition` holds, or records an issue after `limit`.
@MainActor
func until(limit: Duration = .seconds(30), _ message: String, _ condition: () -> Bool) async {
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
func liveServer(_ studio: Studio, busy: AgentBusy? = nil) throws -> (AgentServer, SocketFolder) {
    let folder = try SocketFolder()
    let server = AgentServer(socket: folder.socket) { [AgentTarget(studio: studio, busy: busy)] }
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
