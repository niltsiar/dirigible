import DirigibleCore
import Foundation
import Testing

struct MarkerCommandTests {
    let package: TemporaryPackage

    init() throws {
        package = try TemporaryPackage(Session(sampleRate: 48_000))
    }

    @Test func eachVerbAppliesItsEdit() async throws {
        #expect(
            try await package.run(
                "marker", "set", "PKG", "--id", "m1", "--name", "Intro", "--at", "48000", "--kind", "chapter")
                == CLIResult(status: 0, stdout: "m1\n", stderr: ""))
        #expect(try package.read().markers == ["m1": Marker(id: "m1", name: "Intro", position: 48_000, kind: .chapter)])

        #expect(
            try await package.run("marker", "set", "PKG", "--id", "m1", "--name", "Start", "--at", "0")
                == CLIResult(status: 0, stdout: "m1\n", stderr: ""))
        // G8 of run 2026-10-11-chapters-in-file: an omitted --kind keeps the kind of an existing marker.
        #expect(try package.read().markers == ["m1": Marker(id: "m1", name: "Start", position: 0, kind: .chapter)])

        let added = try await package.run("marker", "set", "PKG", "--name", "Note", "--at", "10")
        let id = MarkerID(String(added.stdout.dropLast()))
        #expect(added.status == 0 && UUID(uuidString: id.rawValue) != nil)
        #expect(try package.read().markers[id] == Marker(id: id, name: "Note", position: 10, kind: .marker))

        #expect(try await package.run("marker", "remove", "PKG", "m1") == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try package.read().markers.keys.sorted() == [id])
    }

    @Test func refusedEditsExitOne() async throws {
        let before = try package.xml()
        #expect(
            try await package.run("marker", "remove", "PKG", "nope")
                == CLIResult(status: 1, stdout: "", stderr: "Error: no marker \"nope\".\n"))
        #expect(
            try await package.run("marker", "set", "PKG", "--name", "X", "--at", "-1")
                == CLIResult(status: 1, stdout: "", stderr: "Error: a frame is negative or more than 2^40.\n"))
        #expect(try package.xml() == before)
    }

    @Test func markerRefusesUnknownKind() async throws {
        let before = try package.xml()
        #expect(
            try await package.run("marker", "set", "PKG", "--name", "X", "--at", "0", "--kind", "note").status == 64)
        #expect(try package.xml() == before)
    }

    /// Run 2026-10-11-chapters-in-file, C8: `--url` and `--image` set the fields. With `--id` of an
    /// existing marker, each option that is not given keeps its value, and an empty value clears it.
    @Test func aURLAndAnImageAreSetKeptAndCleared() async throws {
        let source = package.folder.appending(path: "art.jpg")
        try EpisodeCommandTests.writeImage(source, width: 300, height: 300)
        #expect(
            try await package.run(
                "marker", "set", "PKG", "--id", "m1", "--name", "Intro", "--at", "48000", "--kind", "chapter",
                "--url", "https://example.com/a", "--image", source.path)
                == CLIResult(status: 0, stdout: "m1\n", stderr: ""))
        let set = try #require(try package.read().markers["m1"])
        let image = try #require(set.image)
        #expect(set.url?.text == "https://example.com/a")
        #expect(try Data(contentsOf: package.url.appending(path: image.path)) == Data(contentsOf: source))

        #expect(try await package.run("marker", "set", "PKG", "--id", "m1", "--name", "Renamed").status == 0)
        var expected = set
        expected.name = "Renamed"
        #expect(try package.read().markers["m1"] == expected, "only the name changes")

        #expect(try await package.run("marker", "set", "PKG", "--id", "m1", "--url", "").status == 0)
        expected.url = nil
        #expect(try package.read().markers["m1"] == expected, "the URL is cleared, the image stays")
        #expect(try await package.run("marker", "set", "PKG", "--id", "m1", "--image", "").status == 0)
        expected.image = nil
        #expect(try package.read().markers["m1"] == expected, "the image is cleared")
    }

    /// C8, G8. Control: a reset of the kind to `marker` on `--id` makes the chapter a marker.
    @Test func setURLOnAChapterKeepsTheChapterKind() async throws {
        try package.edit { try $0.setMarker(Marker(id: "c", name: "Part", position: 960, kind: .chapter)) }
        #expect(
            try await package.run("marker", "set", "PKG", "--id", "c", "--url", "https://example.com")
                == CLIResult(status: 0, stdout: "c\n", stderr: ""))
        #expect(
            try package.read().markers["c"]
                == Marker(id: "c", name: "Part", position: 960, kind: .chapter, url: try WebURL("https://example.com")))
    }

    /// C8, G14. A new marker needs a name and a position: exit 64, and no change.
    @Test func aNewMarkerNeedsANameAndAPosition() async throws {
        let before = try package.xml()
        let missing = "Error: a new marker needs a name and a position.\n"
        for arguments in [["--at", "0"], ["--name", "X"], ["--id", "new", "--url", "https://example.com"]] {
            let result = try await package.run(["marker", "set", "PKG"] + arguments)
            #expect(result.status == 64 && result.stderr == missing, "\(arguments): \(result)")
        }
        #expect(try package.xml() == before)
    }

    /// C1, C8. A bad URL and a URL over 255 bytes exit 64; a refused image exits 1, as
    /// `episode set --artwork`. No change.
    @Test func aBadURLOrImageIsRefused() async throws {
        let before = try package.xml()
        let base = ["marker", "set", "PKG", "--name", "X", "--at", "0"]
        let bad = try await package.run(base + ["--url", "ftp://a.b"])
        #expect(bad.status == 64 && bad.stderr.contains("\"ftp://a.b\" is not an http or https URL."), "\(bad)")
        let head = "https://example.com/"
        let long = head + String(repeating: "a", count: Marker.maximumURLBytes + 1 - head.utf8.count)
        let tooLong = try await package.run(base + ["--url", long])
        #expect(
            tooLong.status == 64 && tooLong.stderr.contains("a marker URL has at most 255 bytes."), "\(tooLong)")
        let source = package.folder.appending(path: "wide.jpg")
        try EpisodeCommandTests.writeImage(source, width: 300, height: 200)
        #expect(
            try await package.run(base + ["--image", source.path])
                == CLIResult(
                    status: 1, stdout: "", stderr: "Error: the artwork is 300 x 200 pixels; it must be square.\n"))
        #expect(try package.xml() == before)
    }
}
