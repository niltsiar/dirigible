import DirigibleCore
import Foundation

/// The exit code, stdout, and stderr of one run of the `dirigible` binary.
struct CLIResult: Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// Runs the `dirigible` binary that `swift test` builds next to the test bundle. stdout and
/// stderr go to files, not pipes, so a large output cannot block the child process.
func dirigible(_ arguments: String...) throws -> CLIResult { try dirigible(arguments) }

func dirigible(_ arguments: [String]) throws -> CLIResult {
    let folder = FileManager.default.temporaryDirectory.appending(path: "dirigible-run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = folder.appending(path: "stdout")
    let errors = folder.appending(path: "stderr")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    FileManager.default.createFile(atPath: errors.path, contents: nil)

    let process = Process()
    process.executableURL = Bundle(for: TemporaryPackage.self).bundleURL
        .deletingLastPathComponent().appending(path: "dirigible")
    process.arguments = arguments
    process.standardOutput = try FileHandle(forWritingTo: output)
    process.standardError = try FileHandle(forWritingTo: errors)
    try process.run()
    process.waitUntilExit()
    return CLIResult(
        status: process.terminationStatus,
        stdout: String(decoding: try Data(contentsOf: output), as: UTF8.self),
        stderr: String(decoding: try Data(contentsOf: errors), as: UTF8.self))
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
    func run(_ arguments: String...) throws -> CLIResult { try run(arguments) }
    func run(_ arguments: [String]) throws -> CLIResult { try dirigible(arguments.map { $0 == "PKG" ? path : $0 }) }

    /// Changes the package through the library, not the CLI.
    func edit(_ body: (inout Session) throws -> Void) throws {
        var session = try read()
        try body(&session)
        try session.write(to: url)
    }
}
