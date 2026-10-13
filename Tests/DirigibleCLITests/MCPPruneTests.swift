import DirigibleCore
import Foundation
import Testing

/// The MCP tool `file_prune` on the files (decision 0047, criterion C16 of run
/// `2026-10-12-remove-unused-files`). It gives the lines of `dirigible file prune`. The test that
/// moves files to the real Trash removes only the exact URLs that the tool gives.
struct MCPPruneTests {
    let fixture: FilePruneTests
    var package: TemporaryPackage { fixture.package }

    init() throws { fixture = try FilePruneTests() }

    func prune(_ arguments: [String: Any] = [:]) async throws -> (text: String, isError: Bool) {
        let call = toolCall(1, "file_prune", arguments.merging(["package": package.path]) { $1 })
        return toolResult(answer(try await mcp([call]), id: 1))
    }

    /// C16: the list of the dry run, and no write.
    @Test func dryRunListsFiles() async throws {
        let (bytes, time) = try fixture.sessionState()

        let result = try await prune(["dry_run": true])

        let (unused, stray) = (fixture.unused, fixture.stray)
        let expected = [unused, stray].sorted().map { "\($0)\t\($0 == unused ? 5 : 7) bytes" }
        #expect(
            result == (
                (expected + ["Unused files: 2 (12 bytes)", "Kept for a backup: 0 (0 bytes)"]).joined(separator: "\n"),
                false
            ))
        let (bytesAfter, timeAfter) = try fixture.sessionState()
        #expect(bytesAfter == bytes && timeAfter == time, "session.xml did not change")
        #expect(fixture.exists(unused) && fixture.exists(stray) && fixture.exists("used.wav"))
    }

    /// C16: the same moves and lines as `dirigible file prune`, with the real Trash.
    @Test func prunesLikeTheCLI() async throws {
        let result = try await prune()

        let lines = result.text.split(separator: "\n").map(String.init)
        let moved = lines.map { $0.split(separator: "\t").map(String.init) }.filter { $0.count == 3 }
        let trashed = moved.map { URL(filePath: $0[2]) }
        defer { for url in trashed { try? FileManager.default.removeItem(at: url) } }
        #expect(!result.isError, "\(result)")
        #expect(moved.map(\.[0]) == [fixture.unused, fixture.stray].sorted())
        #expect(trashed.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "each file is in the Trash")
        #expect(lines.contains("Moved to the Trash: 2 (12 bytes). The space comes back when you empty the Trash."))
        #expect(!fixture.exists(fixture.unused) && !fixture.exists(fixture.stray) && fixture.exists("used.wav"))
        let saved = try package.read()
        #expect(saved.files["spare"] == nil && saved.files["used"] != nil)
    }
}
