import AVFoundation
import DirigibleCore
import Foundation
import Testing

/// `dirigible favorites` and `favorites_add` (F23, C11). The source is the 44100 Hz P of
/// `PasteFromCommandTests` with track t3 and its clip S at start 100, length 44100 (all of the tone).
struct FavoritesCommandTests {
    let package: TemporaryPackage
    let store: URL

    init() throws {
        package = try PasteFromCommandTests.package(tone: true, track: "t1", rate: 44_100)
        try package.edit { session in
            try session.addTrack("t3", name: "Host", layout: .mono)
            try session.place(Clip(id: "S", file: "take1-mic", start: 100, offset: 0, length: 44_100), on: "t3")
        }
        store = package.folder.appending(path: "Support/com.delineas.dirigible/Favorites.dirigible")
    }

    func run(_ arguments: String...) async throws -> CLIResult {
        try await dirigible(arguments.map { $0 == "PKG" ? package.path : $0 }, favorites: store)
    }

    /// The bytes of `session.xml` and of each file in `Clips/` of `url`, by name.
    func bytes(_ url: URL) throws -> [String: Data] {
        let clips = url.appending(path: clipsFolderName)
        var all = ["session.xml": try Data(contentsOf: url.appending(path: "session.xml"))]
        for name in try FileManager.default.contentsOfDirectory(atPath: clips.path) {
            all[name] = try Data(contentsOf: clips.appending(path: name))
        }
        return all
    }

    @Test func add() async throws {
        let source = try bytes(package.url)
        #expect(try await run("favorites", "path") == CLIResult(status: 0, stdout: store.path + "\n", stderr: ""))

        let added = try await run("favorites", "add", "PKG", "Sting", "--from", "0", "--to", "44200", "--track", "t3")

        #expect(added.status == 0 && added.stderr.isEmpty && added.stdout.hasSuffix("\n"), "\(added)")
        let id = BinItemID(String(added.stdout.dropLast()))
        let read = try Session(contentsOf: store)
        #expect(read.sampleRate == 48_000)
        let item = try #require(read.bins.first?.items.first { $0.id == id }, "the printed ID is stored")
        let clip = try #require(item.lanes.first?.clips.first)
        #expect((clip.start, clip.length) == (109, 48_000), "\(clip.start) \(clip.length)")
        let wav = try AVAudioFile(forReading: store.appending(path: "\(clipsFolderName)/take1-mic.wav"))
        #expect(wav.fileFormat.sampleRate == 48_000)
        #expect(try bytes(package.url) == source, "the source does not change")
        let list = try await dirigible(["bin", "list", store.path])
        #expect(list.stdout.hasPrefix("bin ") && list.stdout.contains("item \(id) \"Sting\" range length"), "\(list)")

        let answers = try await mcp(
            [toolCall(1, "favorites_add", ["package": package.path, "name": "Intro", "clips": ["A"]])],
            favorites: store)
        let tool = toolResult(answer(answers, id: 1))
        #expect(!tool.isError, "\(tool)")
        #expect(try Session(contentsOf: store).bins.first?.items.map(\.id) == [id, BinItemID(tool.text)])
    }

    /// The refusal of an unreadable source names its real fault, here a newer version, and the source path.
    @Test func aNewerSourceNamesTheVersion() async throws {
        let text = try String(contentsOf: package.sessionXML, encoding: .utf8)
            .replacing(#/ version="\d+"/#, with: #" version="9999""#)
        try Data(text.utf8).write(to: package.sessionXML)
        let named = "\(package.path)/session.xml was made by a newer version of Dirigible"

        let refused = try await run("favorites", "add", "PKG", "Sting", "--clip", "A")
        let answers = try await mcp(
            [toolCall(1, "favorites_add", ["package": package.path, "name": "Sting", "clips": ["A"]])], favorites: store
        )
        let tool = toolResult(answer(answers, id: 1))

        #expect(refused.status == 2 && refused.stdout.isEmpty, "\(refused)")
        #expect(errorText(refused).hasPrefix(named), "\(refused)")
        #expect(tool.isError && tool.text.hasPrefix(named), "\(tool)")
        #expect(!FileManager.default.fileExists(atPath: store.path), "the refused add makes no store")
    }

    @Test func aHeldStoreRefusesTheAdd() async throws {
        _ = try await run("favorites", "add", "PKG", "Sting", "--clip", "A")
        let before = try bytes(store)
        let held = try PackageLock(store)

        let refused = try await run("favorites", "add", "PKG", "Again", "--clip", "A")

        withExtendedLifetime(held) {}
        #expect(refused.status == 2 && refused.stdout.isEmpty, "\(refused)")
        #expect(refused.stderr.hasPrefix("Error: ") && refused.stderr.contains(store.path), "\(refused.stderr)")
        #expect(try bytes(store) == before, "the held store keeps its bytes")
    }
}
