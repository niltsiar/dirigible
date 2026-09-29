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

func dirigible(_ arguments: [String]) async throws -> CLIResult {
    try await run(
        Bundle(for: TemporaryPackage.self).bundleURL.deletingLastPathComponent().appending(path: "dirigible"),
        arguments)
}

/// Runs `/bin/sh -c script` with `arguments` as `$0`, `$1`, and so on, for example to set a
/// resource limit before an `exec` of the binary.
func dirigible(shell script: String, _ arguments: String...) async throws -> CLIResult {
    try await run(URL(filePath: "/bin/sh"), ["-c", script] + arguments)
}

/// Runs `executable` and waits for its exit without a thread: the termination handler resumes the
/// wait. A run over `limit` is stopped and records an issue, so a hang cannot stop the suite.
private func run(_ executable: URL, _ arguments: [String]) async throws -> CLIResult {
    let folder = FileManager.default.temporaryDirectory.appending(path: "dirigible-run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = folder.appending(path: "stdout")
    let errors = folder.appending(path: "stderr")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    FileManager.default.createFile(atPath: errors.path, contents: nil)

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = try FileHandle(forWritingTo: output)
    process.standardError = try FileHandle(forWritingTo: errors)
    let limit = Duration.seconds(30)
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
            Children.ended()
            continuation.resume(returning: process.terminationStatus)
        }
        Children.started()
        do {
            try process.run()
        } catch {
            Children.ended()
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

/// The count of running children. With `DIRIGIBLE_FLAKE_MONITOR` set, each new peak prints
/// `CLI-CHILDREN peak <n>` for `scripts/flake-monitor/loop.sh`.
private enum Children {
    private static let count = OSAllocatedUnfairLock(initialState: (running: 0, peak: 0))
    private static let printsPeaks = ProcessInfo.processInfo.environment["DIRIGIBLE_FLAKE_MONITOR"] != nil

    static func started() {
        let newPeak = count.withLock { state -> Int? in
            state.running += 1
            guard state.running > state.peak else { return nil }
            state.peak = state.running
            return state.peak
        }
        if printsPeaks, let newPeak { print("CLI-CHILDREN peak \(newPeak)") }
    }

    static func ended() { count.withLock { $0.running -= 1 } }
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
