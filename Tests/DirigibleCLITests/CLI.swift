import DirigibleCore
import Foundation
import Testing
import os

/// The exit code, stdout, and stderr of one run of the `dirigible` binary. With `signaled`, a
/// signal ended the child and `status` is the signal number.
struct CLIResult: Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
    var signaled = false
}

/// Runs the `dirigible` binary that `swift test` builds next to the test bundle. stdout and
/// stderr go to files, not pipes, so a large output cannot block the child process. A run over
/// 30 s (the default `limit` of the shell form) is stopped and fails the test, so a hang cannot stop the suite.
func dirigible(_ arguments: String...) async throws -> CLIResult { try await dirigible(arguments) }

/// With `input`, the child reads that file on stdin. With `socket`, `dirigible mcp` connects to
/// that app socket. With `logs`, the child writes its journal there (decision 0059). With
/// `directory`, the child runs in that folder, for a relative path. With `favorites`, the child
/// uses that Favorites store.
func dirigible(
    _ arguments: [String], input: URL? = nil, socket: URL? = nil, logs: URL? = nil, directory: URL? = nil,
    favorites: URL? = nil
) async throws -> CLIResult {
    try await run(
        dirigibleBinary, arguments, input: input, socket: socket, logs: logs, directory: directory,
        favorites: favorites)
}

/// The `dirigible` binary that `swift test` builds next to the test bundle.
var dirigibleBinary: URL {
    Bundle(for: TemporaryPackage.self).bundleURL.deletingLastPathComponent().appending(path: "dirigible")
}

/// A child process of `executable` that runs in `folder`, the new temporary folder of its launcher,
/// so a relative path in a test never lands in the working folder of the test process (the repo).
/// Each launcher of a CLI child makes its process here. The child gets an app socket path in
/// `folder` with no app, so `dirigible mcp` never reaches a running app (decision 0046), unless
/// `socket` gives another one. The journal folder is `folder/logs`, or `logs`, so no child writes
/// to `~/Library/Logs/Dirigible` (decision 0059). The Favorites store is `favorites`, else a path
/// in `folder`, so no child writes the store of the user (decision 0081).
func childProcess(
    _ executable: URL, _ arguments: [String], in folder: URL, socket: URL? = nil, logs: URL? = nil,
    favorites: URL? = nil
) -> Process {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = folder
    process.environment = ProcessInfo.processInfo.environment.merging([
        "DIRIGIBLE_MCP_SOCKET": (socket ?? folder.appending(path: "no-app.sock")).path,
        "DIRIGIBLE_LOG_FOLDER": (logs ?? folder.appending(path: "logs")).path,
        "DIRIGIBLE_FAVORITES": (favorites ?? folder.appending(path: "Favorites.dirigible")).path,
    ]) { $1 }
    return process
}

/// Runs `/bin/sh -c script` with `arguments` as `$0`, `$1`, and so on, for example to set a
/// resource limit before an `exec` of the binary. The child takes a slot of `slots`.
func dirigible(
    shell script: String, _ arguments: String..., slots: Slots = .shared, limit: Duration = .seconds(30)
) async throws -> CLIResult {
    try await dirigible(shell: script, arguments: arguments, slots: slots, limit: limit)
}

func dirigible(
    shell script: String, arguments: [String], slots: Slots = .shared, limit: Duration = .seconds(30)
) async throws -> CLIResult {
    try await run(URL(filePath: "/bin/sh"), ["-c", script] + arguments, slots: slots, limit: limit)
}

/// Runs `executable` through `launch`. A run over `limit` records an issue, so a hang cannot stop
/// the suite. A child that a signal ends records an issue, because its status alone looks like an
/// exit code.
private func run(
    _ executable: URL, _ arguments: [String], input: URL? = nil, socket: URL? = nil, logs: URL? = nil,
    directory: URL? = nil, favorites: URL? = nil, slots: Slots = .shared, limit: Duration = .seconds(30)
) async throws -> CLIResult {
    let folder = FileManager.default.temporaryDirectory.appending(path: "dirigible-run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = folder.appending(path: "stdout")
    let errors = folder.appending(path: "stderr")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    FileManager.default.createFile(atPath: errors.path, contents: nil)

    let process = childProcess(executable, arguments, in: folder, socket: socket, logs: logs, favorites: favorites)
    if let directory { process.currentDirectoryURL = directory }
    let end = try await launch(process, input: input, output: output, errors: errors, slots: slots, limit: limit)
    let command = "\(executable.path) \(arguments.joined(separator: " "))"
    if end.timedOut {
        Issue.record("\(command) ran for more than \(limit.components.seconds) s")
    } else if end.signaled {
        Issue.record("\(command) ended by signal \(end.status)")
    }
    return CLIResult(
        status: end.status,
        stdout: String(decoding: try Data(contentsOf: output), as: UTF8.self),
        stderr: String(decoding: try Data(contentsOf: errors), as: UTF8.self), signaled: end.signaled)
}

/// The end of a child of `launch`: the exit status or the signal number, and whether the limit
/// stopped it.
struct ChildEnd {
    var status: Int32
    var signaled: Bool
    var timedOut: Bool
}

private let launcher = DispatchQueue(label: "dirigible-tests.child-launch", attributes: .concurrent)

/// Takes a slot of `slots`, starts `process` with `input` on stdin and stdout and stderr in the
/// files `output` and `errors` (nil: the stderr of the test process), and waits for its end. At
/// `limit` the child gets SIGTERM. The open, the spawn, and the close of the streams can block in
/// the kernel for seconds while other children start, so they run on dispatch threads, never on a
/// thread of the concurrency pool: a blocked pool delays each `await` of the test process.
func launch(
    _ process: Process, input: URL? = nil, output: URL, errors: URL?, slots: Slots = .shared, limit: Duration
) async throws -> ChildEnd {
    // Take the slot before the limit task: the limit must not stop a child that has not started.
    await slots.started()
    let child = Child(process)
    let stopped = OSAllocatedUnfairLock(initialState: false)
    let watch = Task {
        try await Task.sleep(for: limit)
        stopped.withLock { $0 = true }
        child.terminate()
    }
    defer { watch.cancel() }
    // The handler is set before the spawn, so a child that exits at once still resumes the
    // continuation. Only the handler resumes it, or the error of the spawn.
    let (status, signaled): (Int32, Bool) = try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { process in
            child.closeStreams()
            slots.ended()
            continuation.resume(returning: (process.terminationStatus, process.terminationReason == .uncaughtSignal))
        }
        launcher.async {
            do {
                try child.run(input: input, output: output, errors: errors)
                if stopped.withLock({ $0 }) { child.terminate() }
            } catch {
                child.closeStreams()
                slots.ended()
                continuation.resume(throwing: error)
            }
        }
    }
    return ChildEnd(status: status, signaled: signaled, timedOut: stopped.withLock { $0 })
}

/// A child process of `launch`. `Process` is not `Sendable`: a dispatch thread starts it, the limit
/// task stops it, and the termination handler closes its streams.
final class Child: @unchecked Sendable {
    private let process: Process
    private let streams = OSAllocatedUnfairLock<[FileHandle]>(initialState: [])
    init(_ process: Process) { self.process = process }

    func run(input: URL?, output: URL, errors: URL?) throws {
        func opened(_ handle: FileHandle) -> FileHandle {
            streams.withLock { $0.append(handle) }
            return handle
        }
        process.standardOutput = opened(try FileHandle(forWritingTo: output))
        if let errors { process.standardError = opened(try FileHandle(forWritingTo: errors)) }
        if let input { process.standardInput = opened(try FileHandle(forReadingFrom: input)) }
        try process.run()
    }

    /// `terminate()` raises on a child that did not start, so `launch` checks the limit again after
    /// the spawn.
    func terminate() { if process.isRunning { process.terminate() } }

    func closeStreams() {
        for handle in streams.withLock({ $0 }) { try? handle.close() }
    }
}

/// At most `bound` running children. `shared` has the width of the concurrency pool, so the CLI
/// children and their test fixtures cannot load the machine past it. A child waits for a free
/// slot with no thread: `ended()` gives its slot to the first waiter (see `waitsLast`). With
/// `DIRIGIBLE_FLAKE_MONITOR` set, each new peak prints `CLI-CHILDREN peak <n>` for `scripts/flake-monitor/loop.sh`.
final class Slots: Sendable {
    private struct State {
        var running = 0
        var peak = 0
        var waiting: [CheckedContinuation<Int?, Never>] = []
        var waitingLast: [CheckedContinuation<Int?, Never>] = []
    }
    static let shared = Slots(bound: ProcessInfo.processInfo.activeProcessorCount)
    /// A child started in a task where this is true gets a slot only when no other child waits. The
    /// fuzz tests set it, so a short test never waits behind their hundreds of children.
    @TaskLocal static var waitsLast = false
    private static let printsPeaks = ProcessInfo.processInfo.environment["DIRIGIBLE_FLAKE_MONITOR"] != nil

    let bound: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(bound: Int) { self.bound = bound }

    /// The highest count of running children.
    var peak: Int { state.withLock { $0.peak } }
    /// The count of children that wait for a free slot.
    var waiting: Int { state.withLock { $0.waiting.count + $0.waitingLast.count } }

    /// Waits for a free slot and takes it.
    func started() async {
        let last = Self.waitsLast
        let newPeak: Int? = await withCheckedContinuation { continuation in
            let slot = state.withLock { [bound] state -> (free: Bool, newPeak: Int?) in
                guard state.running < bound else {
                    if last { state.waitingLast.append(continuation) } else { state.waiting.append(continuation) }
                    return (false, nil)
                }
                state.running += 1
                guard state.running > state.peak else { return (true, nil) }
                state.peak = state.running
                return (true, state.peak)
            }
            if slot.free { continuation.resume(returning: slot.newPeak) }
        }
        if Self.printsPeaks, let newPeak { print("CLI-CHILDREN peak \(newPeak)") }
    }

    /// Frees the slot of a child that ended or did not start. The first waiter gets the slot, so
    /// the count of running children stays the same.
    func ended() {
        let next = state.withLock { state -> CheckedContinuation<Int?, Never>? in
            if !state.waiting.isEmpty { return state.waiting.removeFirst() }
            if !state.waitingLast.isEmpty { return state.waitingLast.removeFirst() }
            state.running -= 1
            return nil
        }
        next?.resume(returning: nil)
    }
}

/// Sends `signal` to `pid` when `ready` turns true, and returns true; returns false after `limit`.
/// A watch of the entries of `folder` checks `ready` on a dispatch queue at each change, so the
/// signal comes in its window also when other tests hold each thread of the concurrency pool.
func send(
    _ signal: Int32, to pid: pid_t, watching folder: URL, limit: Duration, when ready: @escaping @Sendable () -> Bool
) async throws -> Bool {
    let descriptor = open(folder.path, O_EVTONLY)
    try #require(descriptor >= 0, "cannot watch \(folder.path)")
    let sent = OSAllocatedUnfairLock(initialState: false)
    let queue = DispatchQueue(label: "signal-watch")
    let check: @Sendable () -> Void = {
        guard !sent.withLock({ $0 }), ready() else { return }
        kill(pid, signal)
        sent.withLock { $0 = true }
    }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
    source.setEventHandler(handler: check)
    source.setCancelHandler { close(descriptor) }
    source.activate()
    queue.async(execute: check)
    defer { source.cancel() }
    let end = ContinuousClock.now + limit
    while !sent.withLock({ $0 }), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
    return sent.withLock { $0 }
}

/// Writes `digit` over byte 7 of the file at `url`: the version digit of a sidecar or anchor
/// magic (decision 0024 P9).
func setMagicDigit(_ url: URL, _ digit: String) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.seek(toOffset: 7)
    try handle.write(contentsOf: Data(digit.utf8))
    try handle.close()
}

/// A package path `Show.dirigible` in a unique temporary folder, removed at deinit. With a
/// session, the package exists on disk; without one, only the folder exists.
final class TemporaryPackage {
    let folder: URL
    let url: URL
    var path: String { url.path }
    var sessionXML: URL { url.appending(path: "session.xml") }

    init(_ session: Session? = nil) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "DirigibleCLITests-\(UUID().uuidString)")
        url = folder.appending(path: "Show.dirigible")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try session?.write(to: url)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func read() throws -> Session { try Session(contentsOf: url) }
    func xml() throws -> Data { try Data(contentsOf: sessionXML) }

    /// True when both packages hold the same session and the same words. Each transcript file
    /// name is a new UUID, so the names differ (decision 0055).
    func holdsTheSameSession(as other: TemporaryPackage) throws -> Bool {
        func text(_ package: TemporaryPackage) throws -> String {
            String(decoding: try package.xml(), as: UTF8.self).replacing(#/\sfile="[0-9A-F-]{36}"/#, with: "")
        }
        return try text(self) == text(other) && read().words() == other.read().words()
    }

    /// Runs `dirigible` with each "PKG" argument replaced by the package path.
    func run(_ arguments: String...) async throws -> CLIResult { try await run(arguments) }
    func run(_ arguments: [String]) async throws -> CLIResult {
        try await dirigible(arguments.map { $0 == "PKG" ? path : $0 })
    }

    /// Changes the package through the library, not the CLI.
    func edit(_ body: (inout Session) throws -> Void) throws {
        var session = try read()
        try body(&session)
        try session.write(to: url)
    }
}
