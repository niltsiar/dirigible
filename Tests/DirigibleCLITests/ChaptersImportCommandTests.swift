import DirigibleCore
import Foundation
import Testing

/// `dirigible chapters import` and the tool `chapters_import` on the files (C20, C22, C23, C24b of
/// run 2026-10-17-agent-pack). Track `t1` has a clip of 20 s. Chapters "Interview" at 10 s and
/// "Outro" at 12 s with an image, and a plain marker "Note".
struct ChaptersImportCommandTests {
    let package: TemporaryPackage
    static let image = try! ArtworkName("0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.jpg")

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 960_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 960_000), on: "t1")
        try session.setMarker(Marker(id: "a", name: "Interview", position: 480_000, kind: .chapter))
        try session.setMarker(Marker(id: "b", name: "Outro", position: 576_000, kind: .chapter, image: Self.image))
        try session.setMarker(Marker(id: "n", name: "Note", position: 100, kind: .marker))
        package = try TemporaryPackage(session)
    }

    /// Writes a chapters file beside the package and gives its path.
    func file(_ chapters: String, name: String = "show.json", version: String = "1.2.0") throws -> String {
        let url = package.folder.appending(path: name)
        try Data(#"{"version": "\#(version)", "chapters": [\#(chapters)]}"#.utf8).write(to: url)
        return url.path
    }

    func raw(_ text: String) throws -> String {
        let url = package.folder.appending(path: "raw.json")
        try Data(text.utf8).write(to: url)
        return url.path
    }

    /// Name, frame, kind, and image of each marker, by position.
    func shape(_ package: TemporaryPackage) throws -> [String] {
        try package.read().sortedMarkers.map {
            "\($0.name)@\($0.position) \($0.kind.rawValue)\($0.image == nil ? "" : " img")"
        }
    }

    static let timeline = #"{"startTime": 0}, {"startTime": 94.5, "title": "Talk"}, {"startTime": 168, "title": "End"}"#

    /// C22: each fault gives exit 1 with a line that names the chapter by its place, and the
    /// bytes of `session.xml` stay. Control: the next test imports a good file.
    @Test(arguments: [
        ("not json", "PATH: the file is not a JSON object."),
        (
            #"{"version": "1.2.0", "chapters": []}"#,
            "PATH: the file has no chapter: it needs a \"chapters\" array with one chapter or more."
        ),
        (
            #"{"version": "2.0.0", "chapters": [{"startTime": 0}]}"#,
            "PATH: version \"2.0.0\" is not 1.x; Dirigible reads versions 1.x."
        ),
        (#"{"chapters": [{"startTime": 0}]}"#, "PATH: the file has no \"version\"; Dirigible reads versions 1.x."),
        (
            #"{"version": "1.2.0", "chapters": [{"startTime": 0}, {"title": "B"}]}"#,
            "PATH: chapter 2 has no startTime that is a number of seconds, 0 or more."
        ),
        (
            #"{"version": "1.2.0", "chapters": [{"startTime": -1}]}"#,
            "PATH: chapter 1 has no startTime that is a number of seconds, 0 or more."
        ),
        (
            #"{"version": "1.2.0", "chapters": [{"startTime": "5"}]}"#,
            "PATH: chapter 1 has no startTime that is a number of seconds, 0 or more."
        ),
        (
            #"{"version": "1.2.0", "chapters": [{"startTime": 0, "title": "A\u0007B"}]}"#,
            "PATH: the title of chapter 1 has a control character."
        ),
        (
            #"{"version": "1.2.0", "chapters": [{"startTime": 0}, {"startTime": 1e300}]}"#,
            "chapter 2 starts at a frame that is negative or more than 2^40."
        ),
    ])
    func aBadChaptersFileChangesNothing(json: String, line: String) async throws {
        let before = try package.xml()
        let path = try raw(json)
        let result = try await package.run("chapters", "import", "PKG", path)
        #expect(result == CLIResult(status: 1, stdout: "", stderr: "Error: \(line.replacing("PATH", with: path))\n"))
        #expect(try package.xml() == before)

        let missing = package.folder.appending(path: "none.json").path
        let gone = try await package.run("chapters", "import", "PKG", missing)
        #expect(gone.status == 1 && gone.stderr.hasPrefix("Error: cannot read \(missing): "), "\(gone)")
        #expect(try package.xml() == before)
    }

    /// Code gate 1 item 4: a path that is not a regular file, or a file over 1 MiB, is refused
    /// before the read, and the bytes of `session.xml` stay. Control: the same JSON at 1 MiB
    /// imports.
    @Test func aChaptersImportRefusesAFolderOrALargeFile() async throws {
        let before = try package.xml()
        let folder = package.folder.appending(path: "chapters.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let refused = try await package.run("chapters", "import", "PKG", folder.path)
        #expect(refused == CLIResult(status: 1, stdout: "", stderr: "Error: \(folder.path) is not a file.\n"))

        let json = #"{"version": "1.2.0", "chapters": [{"startTime": 3, "title": "Big"}]}"#
        let padded = { (bytes: Int) in json + String(repeating: " ", count: bytes - json.utf8.count) }
        let big = try raw(padded(1_048_577))
        let large = try await package.run("chapters", "import", "PKG", big)
        #expect(large == CLIResult(status: 1, stdout: "", stderr: "Error: \(big) is larger than 1 MiB.\n"))
        #expect(try package.xml() == before)

        let fits = try await package.run("chapters", "import", "PKG", try raw(padded(1_048_576)))
        #expect(fits.status == 0, "\(fits)")
        #expect(try package.read().sortedMarkers.contains { $0.name == "Big" }, "a file of 1 MiB imports")
    }

    /// C20: an `--at` below 0 or past 2^40 is a usage error, before the file is read.
    @Test(arguments: ["-1", "1099511627777", "9223372036854775807"])
    func anAtOutOfRangeIsAUsageError(at: String) async throws {
        let before = try package.xml()
        let result = try await package.run("chapters", "import", "PKG", try file(Self.timeline), "--at", at)
        #expect(result.status == 64 && result.stdout.isEmpty, "\(result)")
        #expect(result.stderr.contains("--at is a frame in 0...2^40."), "\(result.stderr)")
        #expect(try package.xml() == before)
    }

    /// C20: chapters at 0, 94.5, and 168 s at 48 kHz, and the first at `--at`. The old chapters
    /// stay, the output is the marker IDs, and a link or an image that the import cannot take
    /// gives a warning line (C23).
    @Test func aChaptersImportAddsChapterMarkers() async throws {
        let path = try file(Self.timeline)
        let result = try await package.run("chapters", "import", "PKG", path)
        #expect(result.status == 0 && result.stderr.isEmpty, "\(result)")
        let ids = result.stdout.split(separator: "\n").map { MarkerID(String($0)) }
        let session = try package.read()
        #expect(ids.compactMap { session.markers[$0]?.position } == [0, 4_536_000, 8_064_000])
        #expect(ids.compactMap { session.markers[$0]?.name } == ["Chapter 1", "Talk", "End"])
        #expect(session.markers["a"] != nil && session.markers["b"] != nil, "no replace: the old chapters stay")

        let shifted = try await package.run("chapters", "import", "PKG", path, "--at", "240000")
        let more = try package.read()
        let moved = shifted.stdout.split(separator: "\n").map { MarkerID(String($0)) }
        #expect(moved.compactMap { more.markers[$0]?.position } == [240_000, 4_776_000, 8_304_000])

        let fields = try file(
            #"{"startTime": 1, "url": "mailto:a@b.c"}, {"startTime": 2, "img": "x.jpg", "toc": false}"#,
            name: "fields.json")
        let warned = try await package.run("chapters", "import", "PKG", fields)
        #expect(warned.status == 0, "\(warned)")
        #expect(
            warned.stderr
                == "Warning: chapter 1 has a url that is not an http or https link of at most 255 bytes; it is not "
                + "imported.\nWarning: 1 chapter has an img that is not imported: the import copies no image.\n")
    }

    /// C24 and C24b: `--replace` removes the chapters, keeps the plain marker, and gives the image
    /// of "Outro" to the file chapter at 12 s.
    @Test func aReplaceKeepsTheImageAtItsTime() async throws {
        let path = try file(#"{"startTime": 0, "title": "Start"}, {"startTime": 12, "title": "Closing"}"#)
        let result = try await package.run("chapters", "import", "PKG", path, "--replace")
        #expect(result.status == 0 && result.stderr.isEmpty, "\(result)")
        #expect(try shape(package) == ["Start@0 chapter", "Note@100 marker", "Closing@576000 chapter img"])
        #expect(try package.read().markers["a"] == nil && package.read().markers["b"] == nil)
    }

    /// C24b: a removed image with no chapter at its time stops the import: exit 1, a line with the
    /// title and the frame, and the bytes of `session.xml` stay. With no `--replace`, the import goes on.
    @Test func aChaptersImportThatWouldDropAnImageChangesNothing() async throws {
        let before = try package.xml()
        let path = try file(#"{"startTime": 0}, {"startTime": 13}"#)
        let refused = try await package.run("chapters", "import", "PKG", path, "--replace")
        #expect(refused.status == 1 && refused.stdout.isEmpty, "\(refused)")
        #expect(
            refused.stderr
                == "Error: the import would drop the image of \"Outro\" at 576000. The file has no chapter at the same "
                + "time. Remove the chapter first, or add one at that time to the file.\n")
        #expect(try package.xml() == before)

        let added = try await package.run("chapters", "import", "PKG", path)
        #expect(added.status == 0, "\(added)")
        #expect(try package.read().markers["b"]?.image == Self.image)
    }

    /// C20, C7: the tool gives the markers of the command, the same lines, and the same refusals.
    @Test func theChaptersImportToolGivesTheCLIResult() async throws {
        let twin = try TemporaryPackage(package.read())
        let path = try file(
            #"{"startTime": 0}, {"startTime": 94.5, "title": "Talk", "toc": false, "url": "ftp://x/y"}"#)
        let cli = try await twin.run("chapters", "import", "PKG", path, "--at", "480")
        let answers = try await mcp([
            toolCall(1, "chapters_import", ["package": package.path, "path": path, "at": 480])
        ])
        let tool = toolResult(answer(answers, id: 1))
        #expect(!tool.isError && cli.status == 0, "\(tool) \(cli)")
        let lines = tool.text.split(separator: "\n").map(String.init)
        let warning = cli.stderr.split(separator: "\n").map(String.init)
        #expect(lines.count == 2 + warning.count && Array(lines.suffix(warning.count)) == warning, "\(tool.text)")
        #expect(try shape(package) == shape(twin))
        #expect(try package.read().markers.count == 5)
    }

    @Test func theChaptersImportToolKeepsTheRefusalsOfTheCommand() async throws {
        let before = try package.xml()
        let drop = try file(#"{"startTime": 0}, {"startTime": 13}"#, name: "drop.json")
        let bad = try raw(#"{"version": "1.2.0", "chapters": [{"startTime": 0}, {"startTime": 1e300}]}"#)
        let broken = try raw(#"{"version": "3", "chapters": [{"startTime": 0}]}"#)
        let calls: [(arguments: [String: Any], command: [String])] = [
            (["path": drop, "replace": true], [drop, "--replace"]), (["path": bad], [bad]),
            (["path": broken], [broken]),
        ]
        for (arguments, command) in calls {
            let cli = try await package.run(["chapters", "import", "PKG"] + command)
            let answers = try await mcp([
                toolCall(1, "chapters_import", arguments.merging(["package": package.path]) { $1 })
            ])
            #expect(toolResult(answer(answers, id: 1)) == (errorText(cli), true), "\(command)")
        }
        let relative = try await mcp([toolCall(1, "chapters_import", ["package": package.path, "path": "x.json"])])
        #expect(toolResult(answer(relative, id: 1)) == ("The argument \"path\" must be an absolute path.", true))
        for at in [-1, 1_099_511_627_777] {
            let answers = try await mcp([
                toolCall(1, "chapters_import", ["package": package.path, "path": drop, "at": at])
            ])
            #expect(toolResult(answer(answers, id: 1)) == ("at is a frame in 0...2^40.", true), "\(at)")
        }
        #expect(try package.xml() == before)
    }
}
