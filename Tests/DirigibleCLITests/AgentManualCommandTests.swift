import ArgumentParser
import Foundation
import Testing

@testable import DirigibleCLI
@testable import DirigibleMCP

/// `dirigible --instructions`, `dirigible skill show`, and `dirigible skill path` (decision 0051).
struct AgentManualCommandTests {
    @Test func theFlagPrintsTheInstructionsOfBothEras() async throws {
        let printed = try await dirigible("--instructions")
        #expect(printed.status == 0 && printed.stderr.isEmpty, "\(printed)")
        #expect(printed.stdout.hasSuffix("\n") && printed.stdout.contains("Recipes (also MCP prompts):"))
        let legacy = try await mcp([MCPProtocolTests.initializeLine])
        let modern = try await mcp([MCPProtocolTests.discoverLine])
        let served = [
            result(answer(legacy, id: 1))["instructions"] as? String,
            result(answer(modern, id: "server-discover-probe-1"))["instructions"] as? String,
        ]
        let text = String(printed.stdout.dropLast())
        #expect(served.allSatisfy { $0 == text }, "the instructions of the server differ from --instructions")
    }

    @Test func theManualNamesTheCLIPath() async throws {
        let temporary = try TemporaryPackage()
        let folder = temporary.folder
        let link = folder.appending(path: "bin/dirigible")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dirigibleBinary)
        let result = try await dirigible(shell: #"exec "$0" --instructions"#, link.path)
        let resolved = shellQuoted(dirigibleBinary.resolvingSymlinksInPath().path)
        #expect(result.stdout.contains("The CLI is \(resolved). Below,"), "\(result.stdout.prefix(400))")
        #expect(!result.stdout.contains(link.path))
        // A copy under /var, a link to /private/var: the manual names the real path, as the client
        // registers it (Phase 7: the E38 allow rule refused the /tmp form of /private/tmp).
        let copy = folder.appending(path: "copy/dirigible")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dirigibleBinary, to: copy)
        let real = try #require(realpath(copy.path, nil))
        defer { free(real) }
        #expect(String(cString: real).hasPrefix("/private/"), "the temporary folder is not under /private")
        let copied = try await dirigible(shell: #"exec "$0" --instructions"#, copy.path)
        #expect(
            copied.stdout.contains("The CLI is \(shellQuoted(String(cString: real))). Below,"),
            "\(copied.stdout.prefix(300))")
        withExtendedLifetime(temporary) {}
    }

    @Test func theHelpStaysTheHelp() async throws {
        for arguments in [[], ["help"], ["--help"]] {
            let result = try await dirigible(arguments)
            #expect(result.status == 0, "\(arguments): \(result)")
            #expect(
                result.stdout.contains("USAGE: dirigible") && result.stdout.contains("--instructions"), "\(arguments)")
            #expect(!result.stdout.contains("Rules:"), "\(arguments) prints the manual")
        }
        let version = try await dirigible("--version")
        #expect(version == CLIResult(status: 0, stdout: "0.0.0\n", stderr: ""))
        #expect(try await dirigible("--instructions", "--version") == version, "the version wins")
        let package = try TemporaryPackage()
        _ = try await dirigible("create", package.path, "--sample-rate", "48000")
        let info = try await dirigible("info", package.path, "--instructions")
        #expect(info.status == 0 && info.stdout.contains("48000") && !info.stdout.contains("Rules:"), "\(info)")
    }

    @Test func skillShowIsTheManual() async throws {
        let shown = try await dirigible("skill", "show")
        #expect(shown.status == 0 && shown.stdout == AgentManual.skill)
        let text = shown.stdout
        #expect(text.hasPrefix("---\nname: dirigible\ndescription: ") && text.contains("\n---\n"))
        // The realpath step goes first, and the /Applications path is only for a copy (Phase 7: an
        // agent skipped the step and ran the CLI of /Applications, which the allow rule refused).
        #expect(text.contains("First run `realpath <the base folder of this skill>`"))
        #expect(text.contains("Only when the result is not in an app (a copy of this skill)"))
        let absolute = text.matches(of: /[\s`'"(](\/[^\s`'")]+)/).map { String($0.1) }
        #expect(absolute == ["/Applications/Dirigible.app/Contents/Helpers/dirigible"], "\(absolute)")
        for recipe in AgentManual.recipes {
            #expect(text.contains(recipe.title) && text.contains(recipe.steps), "\(recipe.name)")
        }
    }

    @Test func skillPathOutsideAnAppFails() async throws {
        let result = try await dirigible("skill", "path")
        #expect(result.status == 1 && result.stdout.isEmpty, "\(result)")
        #expect(result.stderr.contains("dirigible skill show"), "\(result.stderr)")
    }

    @Test func skillPathInAnAppNamesTheFile() async throws {
        let temporary = try TemporaryPackage()
        let contents = temporary.folder.appending(path: "Fake.app/Contents")
        let tool = contents.appending(path: "Helpers/dirigible")
        let skill = contents.appending(path: "Resources/skills/dirigible/SKILL.md")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dirigibleBinary, to: tool)
        let missing = try await dirigible(shell: #"exec "$0" skill path"#, tool.path)
        #expect(missing.status == 1 && missing.stderr.contains("dirigible skill show"), "\(missing)")
        try FileManager.default.createDirectory(
            at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: skill)
        let found = try await dirigible(shell: #"exec "$0" skill path"#, tool.path)
        #expect(found == CLIResult(status: 0, stdout: skill.resolvingSymlinksInPath().path + "\n", stderr: ""))
        withExtendedLifetime(temporary) {}
    }

    /// C5: each `dirigible ...` span of the manual, the skill, and the recipes parses.
    @Test func eachCommandExampleParses() {
        let texts = [AgentManual.instructions, AgentManual.skill] + AgentManual.recipes.map(\.steps)
        let lines = texts.flatMap(ManualScan.commandLines)
        #expect(lines.count >= 6, "the scan found \(lines)")
        for line in lines { #expect(Self.parses(line), "\(line) does not parse") }
    }

    @Test func aBadExampleIsFound() {
        #expect(!Self.parses("dirigible export <p> --out x.mp3 --loudness -16"))
        #expect(!Self.parses("dirigible frobnicate"))
        #expect(Self.parses("dirigible export <package> --out <file.mp3> --loudness podcast"))
    }

    /// The span with each `<hole>` filled parses with the root parser.
    static func parses(_ line: String) -> Bool {
        let filled = line.replacing(/<([^>]+)>/) { hole in
            switch hole.1 {
            case "package", "p": "/tmp/Show.dirigible"
            case let name where name.hasSuffix(".mp3"): "/tmp/out.mp3"
            case "seconds", "frame": "10"
            default: "x"
            }
        }
        let words = filled.split(separator: " ").map(String.init)
        guard words.first == "dirigible" else { return false }
        return (try? Dirigible.parseAsRoot(Array(words.dropFirst()))) != nil
    }
}
