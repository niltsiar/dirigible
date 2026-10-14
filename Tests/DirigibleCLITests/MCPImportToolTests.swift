import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The `import` tool of `dirigible mcp` on the files (decision 0049). The package of
/// `ImportCommandTests`, track `T` (mono); the tool and the command each get their own copy.
struct MCPImportToolTests {
    /// A package and a source file `Intro.wav` of 1 s beside it.
    func fixture() throws -> (TemporaryPackage, URL) {
        let package = try ImportCommandTests.package()
        let source = package.folder.appending(path: "Intro.wav")
        try ImportCommandTests.write(source, .wav(.bits24), ImportCommandTests.quiet)
        return (package, source)
    }

    /// The names in `Clips/`.
    func clips(_ package: TemporaryPackage) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: "Clips").path)) ?? []
    }

    /// C13: the tool gives the clip ID of `dirigible import`, and the error text of its refusals.
    @Test func theToolTextIsTheCommandText() async throws {
        let cases: [(cli: [String], tool: [String: Any])] = [
            (["--track", "T", "--at", "48000"], ["track": "T", "at": 48_000]),
            ([], [:]),
            (["--no-level"], ["no_level": true]),
            (["--track", "nope"], ["track": "nope"]),
            (["--at=-1"], ["at": -1]),
        ]
        for (index, item) in cases.enumerated() {
            let ((cli, cliSource), (tool, toolSource)) = (try fixture(), try fixture())
            let run = try await cli.run(["import", "PKG", cliSource.path] + item.cli)
            let arguments = item.tool.merging(["package": tool.path, "file": toolSource.path]) { $1 }
            let answers = try await mcp([toolCall(1, "import", arguments)])
            let expected = run.status == 0 ? (String(run.stdout.dropLast()), false) : (errorText(run), true)
            #expect(toolResult(answer(answers, id: 1)) == expected, "case \(index): \(run)")
            // A new track gets a new random ID, so only an import onto `T` writes the same bytes.
            if item.tool["track"] != nil {
                #expect(try tool.xml() == cli.xml(), "case \(index): the tool and the command wrote the same session")
            }
        }
        // A file that is not audio names the path that the agent gave.
        let (package, _) = try fixture()
        let text = package.folder.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)
        let run = try await package.run("import", "PKG", text.path)
        let answers = try await mcp([toolCall(1, "import", ["package": package.path, "file": text.path])])
        #expect(run.status == 1 && toolResult(answer(answers, id: 1)) == (errorText(run), true), "\(run)")
    }

    @Test func aRelativeFileIsRefused() async throws {
        let (package, _) = try fixture()
        let answers = try await mcp([toolCall(1, "import", ["package": package.path, "file": "Intro.wav"])])
        #expect(toolResult(answer(answers, id: 1)) == ("The argument \"file\" must be an absolute path.", true))
        #expect(clips(package).isEmpty, "a refused import made a file")
    }

    /// A cancel leaves `session.xml` as it was and no new WAV in `Clips/`, and the call gets no
    /// answer.
    @Test func aCancelEndsTheImport() async throws {
        let (package, source) = try fixture()
        let before = try package.xml()
        let lines = try await mcpLines([
            toolCall(2, "import", ["package": package.path, "file": source.path], token: 1), cancelLine(2),
            modernRequest(3, "ping"),
        ])
        #expect(lines.contains { $0["id"] as? Int == 3 }, "the ping after the cancel has its answer: \(lines)")
        #expect(!lines.contains { $0["id"] as? Int == 2 }, "a cancelled import has no answer: \(lines)")
        #expect(try package.xml() == before, "a cancelled import changed session.xml")
        #expect(clips(package).isEmpty, "a cancelled import left \(clips(package))")
    }

    /// C1: the arguments are the options of the command, with `_` for `-`, and the CLI defaults.
    @Test func theArgumentsAreTheOptions() async throws {
        let answers = try await mcp([modernRequest(1, "tools/list")])
        let tools = result(answer(answers, id: 1))["tools"] as? [[String: Any]] ?? []
        let schema = tools.first { $0["name"] as? String == "import" }?["inputSchema"] as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        #expect(Set(properties.keys) == ["package", "file", "track", "at", "no_level"], "\(properties.keys)")
        #expect(properties["at"]?["default"] as? Int == 0 && properties["no_level"]?["default"] as? Bool == false)
        #expect((schema["required"] as? [String]) == ["package", "file"])
    }
}
