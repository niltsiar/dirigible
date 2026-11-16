import Foundation
import Testing

/// The MCP tools refuse a package from another person that breaks a rule of the package format
/// (decision 0003), with an error result and no output of its content.
struct MCPPackageRefusalTests {
    /// C15. `Clips` is a link to a folder outside the package: `file_prune` with `dry_run` refuses the package, so it
    /// lists no file of the link target.
    @Test func filePruneRefusesAClipsLink() async throws {
        let package = try PackageRefusalCommandTests.pruneEscape()

        let call = toolCall(1, "file_prune", ["package": package.path, "dry_run": true])
        let result = toolResult(answer(try await mcp([call]), id: 1))

        #expect(result == (PackageRefusalCommandTests.unsafeItemText(package, "Clips"), true))
        #expect(try PackageRefusalCommandTests.victimFiles(package) == PackageRefusalCommandTests.victim)
    }

    /// A placed take WAV that is a FIFO: `session_info` refuses the package at once, and does not
    /// wait for a writer in the read of its raw capture. A hang ends at the limit of `mcp`.
    @Test func sessionInfoRefusesAFIFOPoolFile() async throws {
        let package = try await InfoCommandTests.rawPackage(bows: [1.07e-3])
        let wav = package.url.appending(path: "Clips/take1-1-1.wav").path
        try #require(unlink(wav) == 0 && mkfifo(wav, 0o644) == 0)

        let call = toolCall(1, "session_info", ["package": package.path])
        let result = toolResult(answer(try await mcp([call]), id: 1))

        #expect(result == (PackageRefusalCommandTests.unsafeItemText(package, "Clips/take1-1-1.wav"), true))
    }
}
