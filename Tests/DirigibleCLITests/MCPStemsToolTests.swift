import DirigibleCore
import Foundation
import Testing

@testable import DirigibleMCP

/// The `export_stems` tool of `dirigible mcp` on the files (criterion C10). The package of
/// `StemsCommandTests`.
struct MCPStemsToolTests {
    let command: StemsCommandTests
    var package: TemporaryPackage { command.package }

    init() throws { command = try StemsCommandTests() }

    func out(_ name: String) -> String { package.folder.appending(path: name).path }

    /// Each tool text is the text of the command with the tool name of each option.
    @Test func theToolGivesTheTextOfTheCommand() async throws {
        let cases: [(cli: [String], tool: [String: Any])] = [
            ([], [:]),
            (["--by", "role", "--format", "flac", "--bits", "16"], ["by": "role", "format": "flac", "bits": 16]),
            (["--by", "role", "--track", "s"], ["by": "role", "track": ["s"]]),
            (["--format", "mp3"], ["format": "mp3"]),
            (["--rate", "22050"], ["rate": 22_050]),
            (["--from", "30000", "--to", "40000"], ["from": 30_000, "to": 40_000]),
            (["--track", "nope"], ["track": ["nope"]]),
        ]
        for (index, (cli, tool)) in cases.enumerated() {
            let run = try await package.run(["export-stems", "PKG", "--out", out("cli\(index)")] + cli)
            let arguments = tool.merging(["package": package.path, "out": out("tool\(index)")]) { $1 }
            let answers = try await mcp([toolCall(1, "export_stems", arguments)])
            let expected = MCPExportToolTests.toolText(of: run)
            #expect(toolResult(answer(answers, id: 1)) == expected, "\(cli)")
        }
    }

    /// C6: a cancel ends the call with no answer and leaves no folder, no staging folder, and no
    /// lock file.
    @Test func aCancelLeavesNoFolder() async throws {
        let lines = try await mcpLines([
            toolCall(2, "export_stems", ["package": package.path, "out": out("stems")], token: 1), cancelLine(2),
            modernRequest(3, "ping"),
        ])
        #expect(lines.contains { $0["id"] as? Int == 3 }, "the ping after the cancel has its answer: \(lines)")
        let items = try FileManager.default.contentsOfDirectory(atPath: package.folder.path)
        if lines.contains(where: { $0["id"] as? Int == 2 }) {
            Issue.record("a cancelled export_stems has an answer: \(lines)")
        } else {
            #expect(items == ["Show.dirigible"], "a cancelled export_stems left \(items)")
        }
    }
}
