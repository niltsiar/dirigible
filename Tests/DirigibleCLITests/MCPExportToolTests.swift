import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleMCP

/// The `export` and `render` tools of `dirigible mcp` on the files (decision 0049). The package of
/// `ExportCommandTests`: track `t1` with `f1.wav` at frames 1000..<21 000, and track `t2`, empty.
struct MCPExportToolTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 20_000))
        try session.addFile(AudioFile(id: "gone", path: "gone.wav", layout: .mono, length: 20_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 1000, offset: 0, length: 20_000), on: "t1")
        package = try TemporaryPackage(session)
        try RenderCommandTests.writeWAV(package.url.appending(path: "Clips/f1.wav"), frames: 20_000)
    }

    func out(_ name: String) -> String { package.folder.appending(path: name).path }

    /// The names in the folder of the package, other than the package.
    func outputs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.folder.path).filter { !$0.hasSuffix(".dirigible") }
    }

    /// The tool text of a CLI run: the first error line with no "Error: ", with the tool name of
    /// each option (`allow_missing` for `--allow-missing`), or the stdout lines and then the
    /// stderr lines, or "OK" when the run printed nothing.
    func toolText(of run: CLIResult) -> (text: String, isError: Bool) {
        guard run.status == 0 else {
            let first = run.stderr.split(separator: "\n").first.map(String.init) ?? ""
            let text = String(first.dropFirst("Error: ".count))
            return (text.replacing(/--([a-z][a-z-]*)/) { $0.1.replacing("-", with: "_") }, true)
        }
        let lines = (run.stdout + run.stderr).split(separator: "\n").map(String.init)
        return (lines.isEmpty ? "OK" : lines.joined(separator: "\n"), false)
    }

    @Test(arguments: ["export", "render"])
    func aCancelEndsTheJob(tool: String) async throws {
        let target = out(tool == "export" ? "mix.wav" : "mix.caf")
        let lines = try await mcpLines([
            toolCall(2, tool, ["package": package.path, "out": target], token: 1), cancelLine(2),
            modernRequest(3, "ping"),
        ])
        #expect(lines.contains { $0["id"] as? Int == 3 }, "the ping after the cancel has its answer: \(lines)")
        #expect(!lines.contains { $0["id"] as? Int == 2 }, "a cancelled \(tool) has no answer: \(lines)")
        #expect(try outputs() == [], "a cancelled \(tool) left a file")
    }

    /// C5: the end of stdin does not cancel an export.
    @Test func anEOFDoesNotCancelAnExport() async throws {
        let lines = try await mcpLines([
            toolCall(2, "export", ["package": package.path, "out": out("mix.wav")], token: 1)
        ])
        #expect(toolResult(answer(lines, id: 2)) == ("OK", false), "the export after EOF: \(lines)")
        #expect(try outputs() == ["mix.wav"])
    }

    /// C19: an output in the package is refused, also with `replace`, and the take stays.
    @Test func anExportIntoThePackageIsRefused() async throws {
        let take = package.url.appending(path: "Clips/f1.wav")
        let before = try Data(contentsOf: take)
        let answers = try await mcp([
            toolCall(1, "export", ["package": package.path, "out": take.path, "replace": true]),
            toolCall(2, "render", ["package": package.path, "out": package.url.appending(path: "Clips/x.caf").path]),
        ])
        for id in [1, 2] {
            #expect(
                toolResult(answer(answers, id: id)) == ("The output file must be outside the session package.", true))
        }
        #expect(try Data(contentsOf: take) == before, "the take")
    }

    /// C14: `out` must be an absolute path, before any check that reads the working folder.
    @Test func aRelativeOutIsRefused() async throws {
        let answers = try await mcp([
            toolCall(1, "export", ["package": package.path, "out": "mix.wav"]),
            toolCall(2, "render", ["package": package.path, "out": "mix.caf"]),
        ])
        for id in [1, 2] {
            #expect(toolResult(answer(answers, id: id)) == ("The argument \"out\" must be an absolute path.", true))
        }
    }

    /// C13: each tool gives the stdout and then the stderr lines of its command, "OK" for none, and
    /// the error text of a refusal with the tool names of the options (code gate 1 item 5). Clip `c2` of the missing file `gone` is on `t2` at 0..<20 000.
    @Test func theToolTextIsTheCommandText() async throws {
        try package.edit { session in
            try session.place(Clip(id: "c2", file: "gone", start: 0, offset: 0, length: 20_000), on: "t2")
        }
        let cases: [(cli: [String], tool: [String: Any])] = [
            (["--allow-missing", "--loudness", "podcast"], ["allow_missing": true, "loudness": "podcast"]),
            ([], [:]),
            (["--from", "20000"], ["from": 20_000]),
            (["--bits", "20"], ["bits": 20]),
            (["--from", "30000"], ["from": 30_000]),
            (["--track", "t1", "--mono", "--rate", "44100"], ["track": ["t1"], "mono": true, "rate": 44_100]),
        ]
        var calls: [String] = []
        var runs: [CLIResult] = []
        for (index, (cli, tool)) in cases.enumerated() {
            let format = cli.contains("--bits") ? "flac" : "wav"
            runs.append(try await package.run(["export", "PKG", "--out", out("cli\(index).\(format)")] + cli))
            let arguments = tool.merging(["package": package.path, "out": out("tool\(index).\(format)")]) { $1 }
            calls.append(toolCall(index + 1, "export", arguments))
        }
        runs.append(try await package.run("render", "PKG", "--out", out("cli.caf")))
        calls.append(toolCall(cases.count + 1, "render", ["package": package.path, "out": out("tool.caf")]))
        let answers = try await mcp(calls)
        for (index, run) in runs.enumerated() {
            #expect(toolResult(answer(answers, id: index + 1)) == toolText(of: run), "case \(index + 1): \(run)")
        }
    }

    /// C1: the arguments are the options of the command, with `_` for `-`, and the CLI defaults.
    @Test func theArgumentsAreTheOptions() async throws {
        let answers = try await mcp([modernRequest(1, "tools/list")])
        let tools = result(answer(answers, id: 1))["tools"] as? [[String: Any]] ?? []
        for name in ["export", "render"] {
            let help = try await dirigible(name, "--help").stdout
            let options = Set(
                help.matches(of: /--([a-z][a-z-]*)/).map { String($0.1).replacing("-", with: "_") }
            ).subtracting(["help", "version"])
            let schema = tools.first { $0["name"] as? String == name }?["inputSchema"] as? [String: Any] ?? [:]
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            #expect(Set(properties.keys).subtracting(["package"]) == options, "the arguments of \(name)")
            #expect(properties["from"]?["default"] as? Int == 0, "\(name)")
            #expect((schema["required"] as? [String]) == ["package", "out"], "\(name)")
            let outText = properties["out"]?["description"] as? String ?? ""
            #expect(
                !outText.contains("replace") || properties["replace"] != nil, "\(name) out names replace: \(outText)")
        }
        let export = tools.first { $0["name"] as? String == "export" }?["inputSchema"] as? [String: Any] ?? [:]
        let properties = export["properties"] as? [String: [String: Any]] ?? [:]
        for flag in ["mono", "replace", "allow_missing"] {
            #expect(properties[flag]?["default"] as? Bool == false, "\(flag)")
        }
    }

    /// C21: a cancel on a live pipe ends a long export after its first progress line. The MP3
    /// export of 60 s runs for seconds in a debug build (U13: about 275 s for 1 h).
    @Test func aPipeCancelEndsALongExport() async throws {
        try RenderCommandTests.writeWAV(package.url.appending(path: "Clips/long.wav"), frames: 2_880_000)
        try package.edit { session in
            try session.addFile(AudioFile(id: "long", path: "long.wav", layout: .mono, length: 2_880_000))
            try session.place(Clip(id: "c2", file: "long", start: 0, offset: 0, length: 2_880_000), on: "t2")
        }
        let call = toolCall(2, "export", ["package": package.path, "out": out("mix.mp3")], token: 1)
        let lines = try await mcpCancelOverPipe(call, cancel: cancelLine(2), then: modernRequest(3, "ping"))
        #expect(lines.contains { $0.contains("notifications/progress") }, "no progress line: \(lines)")
        #expect(lines.contains { $0.contains(#""id":3"#) }, "the ping after the cancel has its answer: \(lines)")
        #expect(!lines.contains { $0.contains(#""id":2"#) }, "a cancelled export has no answer: \(lines)")
        #expect(try outputs() == [], "a cancelled export left a file")
    }
}

/// The `split` argument of `export` (decision 0067, criterion C14): the chapters Intro at 0,
/// Interview at 8000, and Outro at 15 000 give `Ep-01-Intro`, `Ep-02-Interview`, and `Ep-03-Outro`.
extension MCPExportToolTests {
    func addChapters() throws {
        try package.edit { session in
            try session.setMarker(Marker(id: "a", name: "Intro", position: 0, kind: .chapter))
            try session.setMarker(Marker(id: "b", name: "Interview", position: 8000, kind: .chapter))
            try session.setMarker(Marker(id: "c", name: "Outro", position: 15_000, kind: .chapter))
        }
    }

    func exported(_ names: [String]) -> [String] { names.map { out($0 + ".mp3") } }

    @Test func exportWithSplitWritesTheSet() async throws {
        try addChapters()

        let answers = try await mcp([
            toolCall(1, "export", ["package": package.path, "out": out("Ep.mp3"), "split": "chapters"])
        ])

        let names = ["Ep-01-Intro", "Ep-02-Interview", "Ep-03-Outro"]
        #expect(toolResult(answer(answers, id: 1)) == (exported(names).joined(separator: "\n"), false))
        #expect(try outputs().sorted() == names.map { $0 + ".mp3" })
    }

    @Test func splitOtherWordIsAToolError() async throws {
        try addChapters()

        let answers = try await mcp([
            toolCall(1, "export", ["package": package.path, "out": out("Ep.mp3"), "split": "sections"])
        ])

        #expect(toolResult(answer(answers, id: 1)) == ("split must be chapters or markers.", true))
        #expect(try outputs() == [])
    }

    /// C14, H1: `control.isCancelled` turns true in part 3 of 5. The text has the lines of parts 1 and 2
    /// and the stop line, not "The call was cancelled." alone.
    @Test func aCancelledSetOnFilesNamesTheWrittenFiles() throws {
        try RenderCommandTests.writeWAV(package.url.appending(path: "Clips/long.wav"), frames: 384_000)
        try package.edit { session in
            try session.addFile(AudioFile(id: "long", path: "long.wav", layout: .mono, length: 384_000))
            try session.place(Clip(id: "c2", file: "long", start: 0, offset: 0, length: 384_000), on: "t2")
            let starts = [0, 48_000, 96_000, 336_000, 360_000]
            for (index, name) in ["One", "Two", "Three", "Four", "Five"].enumerated() {
                let marker = Marker(
                    id: MarkerID("m\(index)"), name: name, position: Frames(starts[index]), kind: .chapter)
                try session.setMarker(marker)
            }
        }
        let folder = package.folder
        let control = CallControl(
            token: nil, interval: .zero, send: { _ in },
            poll: { _ in
                let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                return items.contains { $0.hasPrefix(".Ep-03") }
            }, step: {})
        let work = ExportWork(
            out: out("Ep.mp3"),
            options: try ExportText.options(
                out: out("Ep.mp3"), bits: nil, bitrate: nil, mono: false, rate: nil, loudness: nil, spelling: .tool),
            from: 0, to: nil, tracks: [], replace: false, allowMissing: false, split: .chapters)

        let thrown = #expect(throws: ToolError.self) {
            try work.run(package.url, path: package.path, control: control)
        }

        let names = ["Ep-01-One", "Ep-02-Two"]
        let stopped = ["Ep-03-Three", "Ep-04-Four", "Ep-05-Five"].map { out($0 + ".mp3") }.joined(separator: ", ")
        let line = "Stopped: 3 files were not written: \(stopped). An existing file at each path did not change."
        #expect(thrown?.message == (exported(names) + [line]).joined(separator: "\n"), "\(String(describing: thrown))")
        #expect(try outputs().sorted() == names.map { $0 + ".mp3" })
    }

    /// Code gate 1 item 12: the check takes the kind of the call. A plain marker is a point of
    /// `markers` only, so `chapters` gives the no-point refusal.
    @Test func theTargetCheckReadsTheKindOfTheCall() throws {
        try package.edit { try $0.setMarker(Marker(id: "m", name: "Note", position: 8000, kind: .marker)) }
        let session = try Session(contentsOf: package.url)
        let work = ExportWork(
            out: out("Ep.mp3"),
            options: try ExportText.options(
                out: out("Ep.mp3"), bits: nil, bitrate: nil, mono: false, rate: nil, loudness: nil, spelling: .tool),
            from: 0, to: nil, tracks: [], replace: false, allowMissing: false)
        let source = try work.source(in: session)

        #expect(try work.splitConfirmations(session, source: source, by: .markers) == [:])
        let refusal = #expect(throws: SplitRefusal.self) {
            try work.splitConfirmations(session, source: source, by: .chapters)
        }
        #expect(refusal?.message == "no chapter in frames 0..<21000." && refusal?.isNoPoint == true)
    }

    /// C8 (code gate 1 item 4): a plain marker at the millisecond of a chapter has no file of its own
    /// in a `markers` split, and the text says so.
    @Test func aDroppedMarkerGetsOneWarningLine() async throws {
        try addChapters()
        try package.edit { try $0.setMarker(Marker(id: "n", name: "Note", position: 8010, kind: .marker)) }

        let answers = try await mcp([
            toolCall(1, "export", ["package": package.path, "out": out("Ep.mp3"), "split": "markers"])
        ])

        let names = ["Ep-01-Intro", "Ep-02-Interview", "Ep-03-Outro"]
        let line =
            "Warning: marker \"Note\" at 8010 starts at the time of the split point before it, or at the end of "
            + "the range; it has no file of its own."
        #expect(toolResult(answer(answers, id: 1)) == ((exported(names) + [line]).joined(separator: "\n"), false))
    }

    /// Lead ruling 1b row 6: the text ends with the line of the older files of the stem.
    @Test func exportWithSplitNamesTheOldFilesOfTheStem() async throws {
        try addChapters()
        let old = out("Ep-05-Outro.mp3")
        try Data("old".utf8).write(to: URL(filePath: old))

        let answers = try await mcp([
            toolCall(1, "export", ["package": package.path, "out": out("Ep.mp3"), "split": "chapters"])
        ])

        let names = ["Ep-01-Intro", "Ep-02-Interview", "Ep-03-Outro"]
        let line = "Warning: 1 older file of this stem stays: \(old). Dirigible does not delete it."
        #expect(toolResult(answer(answers, id: 1)) == ((exported(names) + [line]).joined(separator: "\n"), false))
        #expect(try Data(contentsOf: URL(filePath: old)) == Data("old".utf8))
    }
}

/// Starts `dirigible mcp` with a pipe on stdin and writes `call`. At the first progress line on
/// stdout it writes `cancel` and `then`, and closes stdin. Gives the stdout lines after the exit.
/// Each wait has the 30 s limit of a CLI child.
func mcpCancelOverPipe(_ call: String, cancel: String, then next: String, limit: Duration = .seconds(30))
    async throws -> [String]
{
    let folder = FileManager.default.temporaryDirectory.appending(path: "dirigible-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = folder.appending(path: "stdout")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let stdin = Pipe()
    let process = childProcess(dirigibleBinary, ["mcp"], in: folder)
    process.standardInput = stdin
    process.standardOutput = try FileHandle(forWritingTo: output)
    await Slots.shared.started()
    defer { Slots.shared.ended() }
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    stdin.fileHandleForWriting.write(Data((call + "\n").utf8))
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    var text = ""
    while !text.contains("notifications/progress"), process.isRunning, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
        text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
    }
    // A write to a pipe with no reader would end the test process.
    if process.isRunning { stdin.fileHandleForWriting.write(Data((cancel + "\n" + next + "\n").utf8)) }
    try stdin.fileHandleForWriting.close()
    let exitDeadline = clock.now + limit
    while process.isRunning, clock.now < exitDeadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!process.isRunning, "dirigible mcp did not exit")
    text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
    return text.split(separator: "\n").map(String.init)
}
