import DirigibleCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// `dirigible episode set` and `show`, the MCP tool `episode_set`, and the MP3 tag of `dirigible
/// export` (decision 0045, criteria C5 and C8).
struct EpisodeCommandTests {
    let package: TemporaryPackage

    init() throws {
        package = try TemporaryPackage(Session(sampleRate: 48_000))
    }

    static let allOptions = [
        "--title", "Episodio 12: Café", "--show", "The Show", "--author", "Ana Pérez", "--episode", "12", "--season",
        "3",
        "--date", "2026-10-09", "--language", "fre", "--copyright", "© 2026 Ana", "--explicit", "true", "--summary",
        "Short", "--notes", "Line 1\n\tLine 2", "--episode-url", "https://example.com/ep12", "--feed-url",
        "https://example.com/feed.xml", "--guid", "urn:uuid:1234",
    ]

    static func expected() throws -> Episode {
        var episode = Episode()
        episode.title = try EpisodeLine("Episodio 12: Café")
        episode.show = try EpisodeLine("The Show")
        episode.author = try EpisodeLine("Ana Pérez")
        episode.number = try EpisodeNumber(12)
        episode.season = try EpisodeNumber(3)
        episode.date = try CalendarDate("2026-10-09")
        episode.language = try LanguageCode("fra")
        episode.copyright = try EpisodeLine("© 2026 Ana")
        episode.explicit = true
        episode.summary = try EpisodeNotes("Short")
        episode.notes = try EpisodeNotes("Line 1\n\tLine 2")
        episode.episodeURL = try WebURL("https://example.com/ep12")
        episode.feedURL = try WebURL("https://example.com/feed.xml")
        episode.guid = try EpisodeLine("urn:uuid:1234")
        return episode
    }

    @Test func setStoresEachFieldAndShowPrintsThem() async throws {
        #expect(
            try await package.run(["episode", "set", "PKG"] + Self.allOptions)
                == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try package.read().episode == Self.expected())

        let shown = try await package.run("episode", "show", "PKG")
        #expect(shown.status == 0 && shown.stderr == "")
        #expect(
            shown.stdout == """
                {
                  "author" : "Ana Pérez",
                  "copyright" : "© 2026 Ana",
                  "date" : "2026-10-09",
                  "episodeURL" : "https://example.com/ep12",
                  "explicit" : true,
                  "feedURL" : "https://example.com/feed.xml",
                  "guid" : "urn:uuid:1234",
                  "language" : "fra",
                  "notes" : "Line 1\\n\\tLine 2",
                  "number" : 12,
                  "season" : 3,
                  "show" : "The Show",
                  "summary" : "Short",
                  "title" : "Episodio 12: Café"
                }

                """, "show printed: \(shown.stdout)")
        let info = try await package.run("info", "PKG", "--json")
        #expect(
            info.stdout.contains("\"episode\" : {") && info.stdout.contains("\"version\" : 6"), "info: \(info.stdout)")
    }

    @Test func anEmptyValueClearsOnlyItsField() async throws {
        _ = try await package.run(["episode", "set", "PKG"] + Self.allOptions)
        #expect(
            try await package.run("episode", "set", "PKG", "--title", "", "--episode", "", "--explicit", "false").status
                == 0)
        var expected = try Self.expected()
        expected.title = nil
        expected.number = nil
        expected.explicit = false
        #expect(try package.read().episode == expected)
    }

    @Test func notesComeFromAFileOrStdin() async throws {
        let file = package.folder.appending(path: "notes.txt")
        try Data("From a file\r\nline 2\n".utf8).write(to: file)
        #expect(try await package.run("episode", "set", "PKG", "--notes-file", file.path).status == 0)
        #expect(try package.read().episode.notes?.text == "From a file\nline 2\n")

        try Data("From stdin".utf8).write(to: file)
        let result = try await dirigible(["episode", "set", package.path, "--notes-file", "-"], input: file)
        #expect(result.status == 0 && result.stderr == "", "stderr: \(result.stderr)")
        #expect(try package.read().episode.notes?.text == "From stdin")
    }

    @Test func aBadValueExits64AndChangesNothing() async throws {
        let before = try package.xml()
        let cases: [([String], String)] = [
            (["--episode", "0"], "An episode or season number is from 1 to 99999, not 0."),
            (["--season", "100000"], "An episode or season number is from 1 to 99999, not 100000."),
            (["--feed-url", "ftp://a.b"], "\"ftp://a.b\" is not an http or https URL."),
            (["--date", "2026-02-30"], "\"2026-02-30\" is not a date in the form YYYY-MM-DD."),
            (["--language", "es"], "\"es\" is not an ISO 639-2 language code of three lowercase letters."),
            (["--title", "a\nb"], "A title, show, author, copyright, or GUID is one line, with no tab."),
            (["--explicit", "yes"], "--explicit is true or false."),
            (["--notes", "a", "--notes-file", "-"], "Give --notes or --notes-file, not both."),
        ]
        for (options, message) in cases {
            let result = try await package.run(["episode", "set", "PKG"] + options)
            #expect(result.status == 64 && result.stderr.hasPrefix("Error: \(message)\n"), "\(options): \(result)")
        }
        #expect(try package.xml() == before)
    }

    @Test func theMCPToolSetsTheFields() async throws {
        let pkg = package.path
        let answers = try await mcp([
            toolCall(
                1, "episode_set", ["package": pkg, "title": "Episodio 12: Café", "episode": "12", "explicit": true]),
            toolCall(2, "episode_set", ["package": pkg, "season": "0"]),
        ])
        #expect(toolResult(answer(answers, id: 1)) == ("OK", false))
        #expect(toolResult(answer(answers, id: 2)) == ("An episode or season number is from 1 to 99999, not 0.", true))
        var expected = Episode()
        expected.title = try EpisodeLine("Episodio 12: Café")
        expected.number = try EpisodeNumber(12)
        expected.explicit = true
        #expect(try package.read().episode == expected)
    }

    @Test func anMP3ExportOfAPackageWithAnEpisodeHasTheTag() async throws {
        try package.edit { session in
            try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 20_000))
            try session.addTrack("t1", name: "Host", layout: .mono)
            try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 20_000), on: "t1")
        }
        try RenderCommandTests.writeWAV(package.url.appending(path: "Clips/f1.wav"), frames: 20_000)
        let plain = package.folder.appending(path: "plain.mp3")
        let tagged = package.folder.appending(path: "tagged.mp3")
        #expect(try await package.run("export", "PKG", "--out", plain.path).status == 0)
        _ = try await package.run("episode", "set", "PKG", "--title", "Café")
        #expect(try await package.run("export", "PKG", "--out", tagged.path).status == 0)

        let plainBytes = try Data(contentsOf: plain)
        let taggedBytes = try Data(contentsOf: tagged)
        #expect(plainBytes.prefix(3) != Data("ID3".utf8), "no episode, no tag")
        #expect(
            taggedBytes.prefix(5) == Data("ID3".utf8) + Data([3, 0]), "the tagged export starts with an ID3v2.3 header")
    }

    /// Writes a one-color JPEG of `width` x `height` pixels.
    static func writeImage(_ url: URL, width: Int, height: Int) throws {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
    }

    @Test func artworkCopiesTheImageAndAnEmptyValueClearsIt() async throws {
        let image = package.folder.appending(path: "cover.jpg")
        try Self.writeImage(image, width: 300, height: 300)
        #expect(
            try await package.run("episode", "set", "PKG", "--artwork", image.path)
                == CLIResult(status: 0, stdout: "", stderr: ""))
        let name = try #require(try package.read().episode.artwork)
        #expect(try Data(contentsOf: package.url.appending(path: name.path)) == Data(contentsOf: image))
        let shown = try await package.run("episode", "show", "PKG").stdout
        #expect(shown.contains("\"artwork\" : \"\(name.path)\""), "show printed: \(shown)")

        #expect(try await package.run("episode", "set", "PKG", "--artwork", "").status == 0)
        #expect(try package.read().episode.artwork == nil)
        #expect(FileManager.default.fileExists(atPath: package.url.appending(path: name.path).path), "the file stays")
    }

    /// An image refusal exits 1, as `dirigible import` of a file that is not audio.
    @Test func aRefusedImageExits1AndChangesNothing() async throws {
        let image = package.folder.appending(path: "wide.jpg")
        try Self.writeImage(image, width: 300, height: 200)
        let before = try package.xml()
        let result = try await package.run("episode", "set", "PKG", "--title", "T", "--artwork", image.path)
        #expect(
            result
                == CLIResult(
                    status: 1, stdout: "", stderr: "Error: the artwork is 300 x 200 pixels; it must be square.\n"))
        #expect(try package.xml() == before)
    }

    @Test func theMCPToolSetsTheArtwork() async throws {
        let image = package.folder.appending(path: "cover.jpg")
        let wide = package.folder.appending(path: "wide.jpg")
        try Self.writeImage(image, width: 300, height: 300)
        try Self.writeImage(wide, width: 300, height: 200)
        let answers = try await mcp([
            toolCall(1, "episode_set", ["package": package.path, "artwork": image.path, "title": "T"]),
            toolCall(2, "episode_set", ["package": package.path, "artwork": wide.path]),
        ])
        #expect(toolResult(answer(answers, id: 1)) == ("OK", false))
        #expect(toolResult(answer(answers, id: 2)) == ("the artwork is 300 x 200 pixels; it must be square.", true))
        let episode = try package.read().episode
        #expect(episode.title?.text == "T" && episode.artwork != nil)
    }
}
