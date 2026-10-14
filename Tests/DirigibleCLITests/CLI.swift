import DirigibleCore
import Foundation
import Testing
import os

/// The exit code, stdout, and stderr of one run of the `dirigible` binary.
struct CLIResult: Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// Runs the `dirigible` binary that `swift test` builds next to the test bundle. stdout and
/// stderr go to files, not pipes, so a large output cannot block the child process. A run over
/// 30 s is stopped and fails the test, so a hang cannot stop the suite.
func dirigible(_ arguments: String...) async throws -> CLIResult { try await dirigible(arguments) }

/// With `input`, the child reads that file on stdin. With `socket`, `dirigible mcp` connects to
/// that app socket.
func dirigible(_ arguments: [String], input: URL? = nil, socket: URL? = nil) async throws -> CLIResult {
    try await run(dirigibleBinary, arguments, input: input, socket: socket)
}

/// The `dirigible` binary that `swift test` builds next to the test bundle.
var dirigibleBinary: URL {
    Bundle(for: TemporaryPackage.self).bundleURL.deletingLastPathComponent().appending(path: "dirigible")
}

/// A child process of `executable` that runs in `folder`, the new temporary folder of its launcher,
/// so a relative path in a test never lands in the working folder of the test process (the repo).
/// Each launcher of a CLI child makes its process here. The child gets an app socket path in
/// `folder` with no app, so `dirigible mcp` never reaches a running app (decision 0046), unless
/// `socket` gives another one.
func childProcess(_ executable: URL, _ arguments: [String], in folder: URL, socket: URL? = nil) -> Process {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = folder
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["DIRIGIBLE_MCP_SOCKET": (socket ?? folder.appending(path: "no-app.sock")).path]) { $1 }
    return process
}

/// Runs `/bin/sh -c script` with `arguments` as `$0`, `$1`, and so on, for example to set a
/// resource limit before an `exec` of the binary. The child takes a slot of `slots`.
func dirigible(shell script: String, _ arguments: String..., slots: Slots = .shared) async throws -> CLIResult {
    try await run(URL(filePath: "/bin/sh"), ["-c", script] + arguments, slots: slots)
}

/// Runs `executable` and waits for its exit without a thread: the termination handler resumes the
/// wait. A run over `limit` is stopped and records an issue, so a hang cannot stop the suite.
private func run(
    _ executable: URL, _ arguments: [String], input: URL? = nil, socket: URL? = nil, slots: Slots = .shared
) async throws -> CLIResult {
    let folder = FileManager.default.temporaryDirectory.appending(path: "dirigible-run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = folder.appending(path: "stdout")
    let errors = folder.appending(path: "stderr")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    FileManager.default.createFile(atPath: errors.path, contents: nil)

    let process = childProcess(executable, arguments, in: folder, socket: socket)
    process.standardOutput = try FileHandle(forWritingTo: output)
    process.standardError = try FileHandle(forWritingTo: errors)
    if let input { process.standardInput = try FileHandle(forReadingFrom: input) }
    let limit = Duration.seconds(30)
    // Take the slot before the limit task: the limit must not stop a child that has not started.
    await slots.started()
    let child = Child(process)
    let watch = Task {
        try await Task.sleep(for: limit)
        child.terminate()
        Issue.record(
            "\(executable.path) \(arguments.joined(separator: " ")) ran for more than \(limit.components.seconds) s")
    }
    defer { watch.cancel() }
    // The handler is set before `run()`, inside the continuation, so a child that exits at once
    // still resumes it. Only the handler resumes it, or the error of `run()`.
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { process in
            slots.ended()
            continuation.resume(returning: process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            slots.ended()
            continuation.resume(throwing: error)
        }
    }
    return CLIResult(
        status: status,
        stdout: String(decoding: try Data(contentsOf: output), as: UTF8.self),
        stderr: String(decoding: try Data(contentsOf: errors), as: UTF8.self))
}

/// A child process for the limit task. `Process` is not `Sendable`; the task only stops it.
private final class Child: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { process.terminate() }
}

/// At most `bound` running children. `shared` has the width of the concurrency pool, so the CLI
/// children and their test fixtures cannot load the machine past it. A child waits for a free
/// slot with no thread: `ended()` gives its slot to the first waiter. With `DIRIGIBLE_FLAKE_MONITOR`
/// set, each new peak prints `CLI-CHILDREN peak <n>` for `scripts/flake-monitor/loop.sh`.
final class Slots: Sendable {
    private struct State {
        var running = 0
        var peak = 0
        var waiting: [CheckedContinuation<Int?, Never>] = []
    }
    static let shared = Slots(bound: ProcessInfo.processInfo.activeProcessorCount)
    private static let printsPeaks = ProcessInfo.processInfo.environment["DIRIGIBLE_FLAKE_MONITOR"] != nil

    let bound: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(bound: Int) { self.bound = bound }

    /// The highest count of running children.
    var peak: Int { state.withLock { $0.peak } }
    /// The count of children that wait for a free slot.
    var waiting: Int { state.withLock { $0.waiting.count } }

    /// Waits for a free slot and takes it.
    func started() async {
        let newPeak: Int? = await withCheckedContinuation { continuation in
            let slot = state.withLock { [bound] state -> (free: Bool, newPeak: Int?) in
                guard state.running < bound else {
                    state.waiting.append(continuation)
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
            guard !state.waiting.isEmpty else {
                state.running -= 1
                return nil
            }
            return state.waiting.removeFirst()
        }
        next?.resume(returning: nil)
    }
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
