import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio
@testable import DirigibleMCP

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

    /// Agent-pack C7: the six shape arguments give the clip of the six options of the command.
    @Test func theImportToolShapesTheClip() async throws {
        let ((cli, cliSource), (tool, toolSource)) = (try fixture(), try fixture())
        let options = [
            "--track", "T", "--id", "Sting", "--offset", "4800", "--length", "24000", "--db", "-3", "--fade-in",
            "480", "--fade-out", "960",
        ]
        let run = try await cli.run(["import", "PKG", cliSource.path] + options)
        let arguments: [String: Any] = [
            "package": tool.path, "file": toolSource.path, "track": "T", "id": "Sting", "offset": 4_800,
            "length": 24_000, "db": -3, "fade_in": 480, "fade_out": 960,
        ]
        let answers = try await mcp([toolCall(1, "import", arguments)])

        #expect(run == CLIResult(status: 0, stdout: "Sting\n", stderr: ""), "\(run)")
        #expect(toolResult(answer(answers, id: 1)) == ("Sting", false))
        #expect(try tool.xml() == cli.xml(), "the tool and the command wrote the same session")
        let clip = try #require(try tool.read().clip("Sting")?.clip)
        #expect([clip.offset, clip.length] == [4_800, 24_000] && clip.gain.dB == -3, "\(clip)")
        #expect(clip.fades == Fades(fadeIn: 480, fadeOut: 960) && clip.file == "Intro", "\(clip)")
    }

    /// Agent-pack C2: a frame or a length out of its range is an argument error, and no file is made.
    @Test func aShapeOutOfRangeIsAnArgumentError() async throws {
        let (package, source) = try fixture()
        let range = "offset is a frame in 0...2^40, and length is a length in 1...2^40."
        let fades = "fade_in and fade_out are lengths in 0...2^40."
        let past = (1 << 40) + 1
        let cases: [([String: Any], String)] = [
            (["offset": -1], range), (["length": 0], range), (["offset": past], range), (["length": past], range),
            (["fade_in": -1], fades), (["fade_out": past], fades),
        ]
        for (index, (extra, text)) in cases.enumerated() {
            let arguments = extra.merging(["package": package.path, "file": source.path, "track": "T"]) { $1 }
            let answers = try await mcp([toolCall(1, "import", arguments)])
            #expect(toolResult(answer(answers, id: 1)) == (text, true), "case \(index)")
        }
        #expect(clips(package).isEmpty, "a refused import made a file")
    }

    /// Agent-pack C8: a cancel after `importAudio` returns, on the files, removes the WAV of the
    /// stem; a file at `Clips/X.wav` keeps its bytes. The poll finds the cancel at the third read
    /// after the rename: two in `importAudio` with `db` (no level), then the one in `ImportWork`.
    @Test func aCancelledImportWithAnIDRemovesTheStemWAV() throws {
        let (package, source) = try fixture()
        let folder = package.url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Data("not the import".utf8)
        try bytes.write(to: folder.appending(path: "X.wav"))
        let before = try package.xml()
        let wav = folder.appending(path: "Intro.wav").path
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let control = CallControl(
            token: nil, interval: .zero, send: { _ in },
            poll: { _ in
                reads.withLock { count in
                    if FileManager.default.fileExists(atPath: wav) { count += 1 }
                    return count >= 3
                }
            }, step: {})
        let work = ImportWork(
            file: source.path, target: ImportTarget(track: "T", start: 0, clip: "X", gain: .zero), level: true)

        #expect(throws: ToolError.self) { try work.run(package.url, path: package.path, control: control) }

        #expect(reads.withLock { $0 } == 3, "the cancel came after the return of importAudio")
        #expect(clips(package) == ["X.wav"], "the cancel left \(clips(package))")
        #expect(FileManager.default.contents(atPath: folder.appending(path: "X.wav").path) == bytes)
        #expect(try package.xml() == before, "a cancelled import changed session.xml")
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
        #expect(
            Set(properties.keys)
                == [
                    "package", "file", "track", "at", "no_level", "id", "offset", "length", "db", "fade_in", "fade_out",
                ],
            "\(properties.keys)")
        #expect(properties["at"]?["default"] as? Int == 0 && properties["no_level"]?["default"] as? Bool == false)
        #expect((schema["required"] as? [String]) == ["package", "file"])
    }
}
