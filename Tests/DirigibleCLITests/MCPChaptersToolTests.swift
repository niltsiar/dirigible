import DirigibleCore
import Foundation
import Testing

/// The tool `chapters_export` of `dirigible mcp` on the files (C17, C19 of run
/// 2026-10-17-agent-pack). Track `t1` has a clip at 0..<960 000; chapters at 10 s, 12 s with an
/// image, and 12 s plus 10 frames, which the file leaves out.
struct MCPChaptersToolTests {
    let package: TemporaryPackage

    init() throws {
        let image = try ArtworkName("0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.jpg")
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 960_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 960_000), on: "t1")
        try session.setMarker(Marker(id: "a", name: "Interview", position: 480_000, kind: .chapter))
        try session.setMarker(Marker(id: "b", name: "Outro", position: 576_000, kind: .chapter, image: image))
        try session.setMarker(Marker(id: "c", name: "Outro 2", position: 576_010, kind: .chapter))
        package = try TemporaryPackage(session)
        let source = package.url.appending(path: image.path)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("jpeg bytes".utf8).write(to: source)
    }

    func out(_ name: String) -> String { package.folder.appending(path: name).path }

    /// A new folder beside the package.
    func folder(_ name: String) throws -> URL {
        let url = package.folder.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// C17: the tool writes the bytes of the command and the same images, and its text is the
    /// stderr lines of the command. Both folders use one file name, so the image names match.
    @Test(arguments: ["json", "txt"])
    func theChaptersExportToolWritesTheCLIFile(form: String) async throws {
        let (cli, tool) = (try folder("cli"), try folder("tool"))
        let run = try await package.run(
            "chapters", "export", "PKG", "--out", cli.appending(path: "show.\(form)").path, "--from", "240000", "--to",
            "800000")
        #expect(run.status == 0 && run.stderr.contains("\"Outro 2\""), "\(run)")
        let answers = try await mcp([
            toolCall(
                1, "chapters_export",
                [
                    "package": package.path, "out": tool.appending(path: "show.\(form)").path, "from": 240_000,
                    "to": 800_000,
                ])
        ])

        #expect(toolResult(answer(answers, id: 1)) == (String(run.stderr.dropLast()), false))
        let names = try FileManager.default.contentsOfDirectory(atPath: cli.path).sorted()
        #expect(names == (form == "json" ? ["show-2.jpg", "show.json"] : ["show.txt"]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tool.path).sorted() == names)
        for name in names {
            let same = try Data(contentsOf: cli.appending(path: name)) == Data(contentsOf: tool.appending(path: name))
            #expect(same, "\(name) differs")
        }
    }

    /// C19: the refusals of the command in the words of the tool. No file is written, and the old
    /// file keeps its bytes.
    @Test func theToolKeepsTheRefusalsOfTheCommand() async throws {
        let old = package.folder.appending(path: "old.json")
        try Data("old bytes".utf8).write(to: old)
        let calls: [([String: Any], String)] = [
            (["out": out("none.json"), "to": 480_000], "no chapter in frames 0..<480000."),
            (["out": old.path], "\(old.path) exists."),
            (
                ["out": package.url.appending(path: "x.json").path],
                "The output file must be outside the session package."
            ),
            (["out": out("x.csv")], "out must end in .json or .txt."),
            (["out": "x.json"], "The argument \"out\" must be an absolute path."),
            (
                ["out": out("x.json"), "from": 480_000, "to": 480_000],
                "The range must be 0 or more, with to more than from; the session end is 960000."
            ),
        ]
        let answers = try await mcp(
            calls.enumerated().map { index, call in
                toolCall(index + 1, "chapters_export", call.0.merging(["package": package.path]) { $1 })
            })

        for (index, call) in calls.enumerated() {
            #expect(toolResult(answer(answers, id: index + 1)) == (call.1, true), "call \(index + 1)")
        }
        #expect(try Data(contentsOf: old) == Data("old bytes".utf8), "the old bytes stay")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: package.folder.path).sorted() == [
                "Show.dirigible", "old.json",
            ])
    }
}
