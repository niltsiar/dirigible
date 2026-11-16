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
}
