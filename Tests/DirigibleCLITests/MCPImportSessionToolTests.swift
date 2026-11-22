import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The `import_session` tool of `dirigible mcp` on the files (decisions 0075 and 0049). The tool
/// and the command each get their own copy of the fixture of `ImportSessionCommandTests`.
struct MCPImportSessionToolTests {
    func fixture(rate: Int = 48_000) throws -> (TemporaryPackage, URL) {
        let package = try ImportCommandTests.package()
        return (package, try ImportSessionCommandTests.source(beside: package, rate: rate))
    }

    /// The names in `Clips/`.
    func clips(_ package: TemporaryPackage) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: "Clips").path)) ?? [])
            .sorted()
    }

    /// The session with no track IDs: a new track gets a new random ID.
    func shape(_ package: TemporaryPackage) throws -> [String] {
        let session = try package.read()
        return session.tracks.map { "\($0.name) \($0.isMuted) \(Array($0.clips))" }
            + session.files.values.map(\.path).sorted() + session.sortedMarkers.map { "\($0.name) \($0.position)" }
    }

    /// C10: the tool gives the session and the text of the command, and its refusal lines.
    @Test func importSessionToolMatchesTheCommand() async throws {
        let cases: [(cli: [String], tool: [String: Any])] = [
            ([], [:]),
            (["--at", "48000", "--markers"], ["at": 48_000, "markers": true]),
            (["--at", "\((1 << 40) + 1)"], ["at": (1 << 40) + 1]),
            (["--at=-48000"], ["at": -48_000]),
        ]
        for (index, item) in cases.enumerated() {
            let ((cli, cliSource), (tool, toolSource)) = (try fixture(), try fixture())
            let run = try await cli.run(["import-session", "PKG", cliSource.path] + item.cli)
            let arguments = item.tool.merging(["package": tool.path, "source": toolSource.path]) { $1 }
            let result = toolResult(answer(try await mcp([toolCall(1, "import_session", arguments)]), id: 1))
            if run.status == 0 {
                #expect(!result.isError && result.text.split(separator: "\n").count == 1, "case \(index): \(result)")
                #expect(try shape(tool) == shape(cli), "case \(index): the tool and the command wrote one session")
            } else {
                let expected = errorText(run).replacing(cliSource.path, with: toolSource.path)
                    .replacing(cli.path, with: tool.path)
                #expect(result == (expected, true), "case \(index): \(run)")
            }
        }
    }

    /// The tool gives the lines of the command: the new track IDs, a `marker <ID>` line for each
    /// new marker, and the line with the count of the markers left out.
    @Test func importSessionToolReportsTheMarkers() async throws {
        let (package, source) = try fixture()
        try ImportSessionCommandTests.addMarkers(to: source)
        let arguments: [String: Any] = ["package": package.path, "source": source.path, "markers": true, "at": -24_000]

        let result = toolResult(answer(try await mcp([toolCall(1, "import_session", arguments)]), id: 1))

        let session = try package.read()
        let late = try #require(session.sortedMarkers.first { $0.name == "Late" })
        let lines =
            session.tracks.dropFirst().map(\.id.rawValue) + [
                "marker \(late.id.rawValue)", ImportSessionCommandTests.leftOutOne,
            ]
        #expect(result == (lines.joined(separator: "\n"), false), "\(result)")
    }

    /// C10: progress grows before the answer at another rate, where each file converts.
    @Test func importSessionToolReportsProgress() async throws {
        let (package, source) = try fixture(rate: 44_100)
        let lines = try await mcpLines([
            toolCall(2, "import_session", ["package": package.path, "source": source.path], token: 7)
        ])
        let values = notifications(lines).compactMap { ($0["params"] as? [String: Any])?["progress"] as? Double }
        #expect(!values.isEmpty && zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "\(values)")
        #expect(!toolResult(answer(lines, id: 2)).isError)
    }

    /// C10: a cancel that comes after the renames removes the new WAVs, and `session.xml` stays.
    @Test func importSessionToolCancels() throws {
        let (package, source) = try fixture()
        let before = (try package.xml(), clips(package))
        let renamed = OSAllocatedUnfairLock(initialState: false)
        let folder = package.url.appending(path: "Clips")
        let control = CallControl(
            token: nil, interval: .zero, send: { _ in },
            poll: { _ in
                renamed.withLock { seen in
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                    seen = seen || names.contains { $0.hasSuffix(".wav") && !$0.hasPrefix(".") }
                    return seen
                }
            }, step: {})
        let work = ImportSessionWork(source: source.path, at: 0, markers: false)

        #expect(throws: ToolError.self) { try work.run(package.url, path: package.path, control: control) }

        #expect(renamed.withLock { $0 }, "the cancel came after the renames")
        #expect(clips(package) == before.1, "the cancel left \(clips(package))")
        #expect(try package.xml() == before.0, "a cancelled import changed session.xml")
    }

    /// A target that is deleted after the lock gives the package fault and its text, exit 2.
    @Test func aTargetDeletedAfterTheLockGivesThePackageFault() throws {
        let (package, source) = try fixture()
        let lock = try PackageLock(package.url)
        var session = try package.read()
        try FileManager.default.removeItem(at: package.url)
        let work = ImportSessionWork(source: source.path, at: 0, markers: false)

        #expect(throws: ImportSessionWork.Failure.target(.packageMoved)) {
            try work.run(&session, lock: lock, package: package.url)
        }

        let failure = ImportSessionWork.Failure.target(.packageMoved)
        #expect(
            failure.message(source: source.path, package: package.path)
                == "\(package.path) moved to another volume or was deleted, so \(package.path)/session.xml did not "
                + "change.")
        #expect(failure.exitCode == 2)
    }

    /// A copy fault of the tool and the command has the words of the import, not of a paste, and
    /// names the source.
    @Test func aCopyFaultOfTheToolNamesTheImport() {
        func text(_ fault: PasteError) -> String {
            SessionImportError.paste(fault).message(source: "/s/Guest.dirigible", package: "/p/Host.dirigible")
        }
        for fault in [PasteError.sourceMissing(file: "a.wav"), .space(needed: 2, free: 1), .cancelled] {
            #expect(!text(fault).contains("paste"), "\(text(fault))")
        }
        #expect(text(.space(needed: 2, free: 1)) == "the import needs 2 free bytes, and the disk has 1.")
        #expect(
            text(.sourceMissing(file: "a.wav"))
                == "the source file \"a.wav\" is not there: /s/Guest.dirigible moved, or the file was deleted.")
        #expect(text(.cancelled) == "the import was cancelled.")
        #expect(
            text(.notDownloaded(file: "session.xml"))
                == "the file \"session.xml\" of /s/Guest.dirigible is not on this Mac, so Dirigible does not import "
                + "/s/Guest.dirigible. Download that session first.")
    }
}
