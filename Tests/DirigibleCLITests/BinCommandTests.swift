import DirigibleCore
import Foundation
import Testing

/// `dirigible bin` and its tools (F22, C10). Each edit exits 0 and changes `session.xml` as
/// `Session(contentsOf:)` reads it, `list` prints literal lines, and a refusal exits 1 with one
/// `Error:` line and no change. Each tool gives the result of its command.
struct BinCommandTests {
    let package: TemporaryPackage

    /// P of `PasteFromCommandTests` (track t1 with clips A, 0..<24000, and C, 24000..<48000, of a 1 s
    /// tone), and track t2 with clip B (12000..<36000) of the tone.
    init() throws {
        package = try Self.package(track: "t1")
    }

    static func package(track: TrackID) throws -> TemporaryPackage {
        let package = try PasteFromCommandTests.package(tone: true, track: track, rate: 48_000)
        try package.edit { session in
            try session.addTrack("t2", name: "Guest", layout: .mono)
            try session.place(Clip(id: "B", file: "take1-mic", start: 12_000, offset: 0, length: 24_000), on: "t2")
        }
        return package
    }

    private let silent = CLIResult(status: 0, stdout: "", stderr: "")

    /// The one stdout line of an edit that prints an ID.
    private func id(_ result: CLIResult) -> String {
        #expect(result.status == 0 && result.stderr.isEmpty && result.stdout.hasSuffix("\n"), "\(result)")
        return String(result.stdout.dropLast())
    }

    /// C10: add a bin, add a range item and a clip-set item, list them, and paste the range item
    /// after its source clips are deleted.
    @Test func addListPaste() async throws {
        #expect(try await package.run("bin", "list", "PKG") == CLIResult(status: 0, stdout: "No bins.\n", stderr: ""))
        let bin = id(try await package.run("bin", "add", "PKG", "Interviews"))
        let range = id(
            try await package.run(
                "bin", "item-add", "PKG", bin, "Good answer", "--from", "6000", "--to", "30000", "--track", "t1",
                "--track", "t2"))
        let sting = id(try await package.run("bin", "item-add", "PKG", bin, "Sting", "--clip", "C"))

        let list = try await package.run("bin", "list", "PKG")

        let lines = [
            "bin \(bin) \"Interviews\"", "item \(range) \"Good answer\" range length 24000 tracks t1,t2",
            "item \(sting) \"Sting\" clips length 24000 tracks t1",
        ]
        #expect(list == CLIResult(status: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: ""))
        let saved = try package.read()
        #expect(saved.bins.map(\.id.rawValue) == [bin] && saved.bins.first?.name == "Interviews")
        #expect(saved.bins.first?.items.map(\.name) == ["Good answer", "Sting"])

        try package.edit { session in try session.removeClips(["A", "B", "C"]) }
        let paste = try await package.run("bin", "paste", "PKG", range, "--at", "96000")

        #expect(paste.status == 0 && paste.stderr.isEmpty, "\(paste)")
        let pasted = paste.stdout.split(separator: "\n").map(String.init)
        #expect(pasted.sorted() == ["A@96000", "B@102000", "C@114000"], "\(paste.stdout)")
        let session = try package.read()
        let a = session.clip("A@96000")
        #expect(a?.track == "t1" && a?.clip.offset == 6_000 && a?.clip.length == 18_000, "\(String(describing: a))")
        #expect(session.clip("B@102000")?.track == "t2" && session.clip("C@114000")?.clip.length == 6_000)
    }

    /// C10: `--insert` moves the later clips of all tracks by the item length.
    @Test func insertMovesTheLaterClips() async throws {
        let bin = id(try await package.run("bin", "add", "PKG", "Show"))
        let item = id(try await package.run("bin", "item-add", "PKG", bin, "Sting", "--clip", "A"))

        let insert = try await package.run("bin", "paste", "PKG", item, "--at", "0", "--insert")

        #expect(insert == CLIResult(status: 0, stdout: "A@0\n", stderr: ""))
        let session = try package.read()
        #expect(session.clip("A")?.clip.start == 24_000 && session.clip("C")?.clip.start == 48_000)
        #expect(session.clip("B")?.clip.start == 36_000 && session.clip("A@0")?.clip.start == 0)
    }

    /// C10: rename, move, and remove a bin, and rename and remove an item. Each prints nothing.
    @Test func renameMoveRemove() async throws {
        let first = id(try await package.run("bin", "add", "PKG", "Interviews"))
        let second = id(try await package.run("bin", "add", "PKG", "Later"))
        let item = id(try await package.run("bin", "item-add", "PKG", first, "Sting", "--clip", "A"))
        let other = id(try await package.run("bin", "item-add", "PKG", first, "Bed", "--clip", "B"))

        #expect(try await package.run("bin", "move", "PKG", second, "--index", "0") == silent)
        #expect(try package.read().bins.map(\.name) == ["Later", "Interviews"])
        #expect(try await package.run("bin", "rename", "PKG", first, "  Talk ") == silent)
        #expect(try await package.run("bin", "item-rename", "PKG", item, "Intro") == silent)
        #expect(try await package.run("bin", "item-remove", "PKG", other) == silent)
        let renamed = try package.read().bins
        #expect(renamed.map(\.name) == ["Later", "Talk"] && renamed.last?.items.map(\.name) == ["Intro"])
        #expect(try await package.run("bin", "remove", "PKG", second) == silent)
        #expect(try package.read().bins.map(\.id.rawValue) == [first])
    }

    /// C10: an unknown bin or item, a place past the list, and a name of only spaces exit 1 with one
    /// `Error:` line, and `session.xml` keeps its bytes. Two selections exit 64.
    @Test func refusalsChangeNothing() async throws {
        let bin = id(try await package.run("bin", "add", "PKG", "Show"))
        let refusals: [([String], String)] = [
            (["rename", "PKG", "ghost", "Talk"], "no bin \"ghost\"."),
            (["item-add", "PKG", "ghost", "Sting", "--clip", "A"], "no bin \"ghost\"."),
            (["move", "PKG", bin, "--index", "1"], "place 1 is not in the bin list."),
            (["rename", "PKG", bin, "   "], "a name must have a character that is not a space."),
            (["item-remove", "PKG", "ghost"], "no bin item \"ghost\"."),
            (["paste", "PKG", "ghost", "--at", "0"], "no bin item \"ghost\"."),
        ]
        for (arguments, message) in refusals {
            let before = try package.xml()
            let result = try await package.run(["bin"] + arguments)
            #expect(result == CLIResult(status: 1, stdout: "", stderr: "Error: \(message)\n"), "\(arguments)")
            #expect(try package.xml() == before, "\(arguments) changed session.xml")
        }
        let both = try await package.run(
            "bin", "item-add", "PKG", bin, "Sting", "--clip", "A", "--from", "0", "--to", "100", "--track", "t1")
        #expect(both.status == 64 && both.stderr.contains("Give --from, --to, and --track, or --clip."))
    }

    /// `bin paste --source` copies the files of an item of another package into this one (0042).
    @Test func pasteFromAnotherPackageCopiesTheFiles() async throws {
        let bin = id(try await package.run("bin", "add", "PKG", "Show"))
        let item = id(try await package.run("bin", "item-add", "PKG", bin, "Sting", "--clip", "C"))
        let target = try PasteFromCommandTests.package(tone: false, track: "u1", rate: 48_000)

        let paste = try await target.run(
            "bin", "paste", "PKG", item, "--source", package.path, "--at", "0", "--onto", "u1")

        #expect(paste == CLIResult(status: 0, stdout: "C@0\n", stderr: ""))
        let session = try target.read()
        #expect(session.clip("C@0")?.clip.file == "take1-mic 2" && session.clip("C@0")?.track == "u1")
        let copied = FileManager.default.contents(
            atPath: target.url.appending(path: "\(clipsFolderName)/take1-mic 2.wav").path)
        #expect(
            copied != nil
                && copied
                    == FileManager.default.contents(
                        atPath: package.url.appending(path: "\(clipsFolderName)/take1-mic.wav").path)
        )
    }

    /// C10: the tools give the text of their commands and the same session.
    @Test func theToolsGiveTheResultsOfTheCommands() async throws {
        let tools = try Self.package(track: "t1")
        func call(_ tool: String, _ arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
            let answers = try await mcp([toolCall(1, tool, ["package": tools.path].merging(arguments) { $1 })])
            return toolResult(answer(answers, id: 1))
        }
        #expect(try await call("bin_list", [:]) == ("No bins.", false))
        let bin = try await call("bin_add", ["name": "Interviews"]).text
        let item = try await call(
            "bin_item_add", ["bin": bin, "name": "Good answer", "from": 6_000, "to": 30_000, "track": ["t1", "t2"]]
        ).text
        let clips = try await call("bin_item_add", ["bin": bin, "name": "Sting", "clips": ["C"]]).text
        let list = try await call("bin_list", [:])
        #expect(
            list.text
                == "bin \(bin) \"Interviews\"\nitem \(item) \"Good answer\" range length 24000 tracks t1,t2\n"
                + "item \(clips) \"Sting\" clips length 24000 tracks t1", "\(list)")
        let paste = try await call("bin_paste", ["item": item, "at": 0, "insert": true])
        #expect(paste.text.split(separator: "\n").sorted() == ["A@0", "B@6000", "C@18000"], "\(paste)")
        #expect(try await call("bin_rename", ["bin": bin, "name": "Talk"]) == ("OK", false))
        #expect(try await call("bin_item_rename", ["item": clips, "name": "Intro"]) == ("OK", false))
        #expect(try await call("bin_move", ["bin": bin, "index": 0]) == ("OK", false))
        #expect(try await call("bin_item_remove", ["item": item]) == ("OK", false))
        let saved = try tools.read()
        #expect(saved.bins.map(\.name) == ["Talk"] && saved.bins.first?.items.map(\.name) == ["Intro"])
        #expect(saved.clip("C")?.clip.start == 48_000, "the insert moved C by 24000")
        #expect(try await call("bin_remove", ["bin": "ghost"]) == ("no bin \"ghost\".", true))
        #expect(try await call("bin_remove", ["bin": bin]) == ("OK", false))
        #expect(try tools.read().bins.isEmpty)
    }
}
