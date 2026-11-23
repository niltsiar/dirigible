import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The Favorites store (F23): one package at 48000 Hz that each add and edit changes under its lock.
/// The source "Show" has track t1 with clip A of the WAV host (1.1 s) at start 100, length 44100.
struct FavoritesTests {
    let source: MixPackage
    /// A Copy of 0..<44200 on t1 of the source.
    let clipboard: Clipboard

    init() throws { try self.init(rate: 48_000) }

    init(rate: Int) throws {
        source = try MixPackage(sampleRate: rate, name: "Show")
        try source.addFile("host", channels: [sine(seconds: 1.1, rate: Double(rate))])
        try source.addTrack("t1", clip: "A", file: "host", start: 100, offset: 0, length: 44_100)
        try source.session.write(to: source.url)
        FileManager.default.createFile(atPath: source.url.appending(path: ".lock").path, contents: nil)
        clipboard = Clipboard(
            try source.session.excerpt(of: 0..<44_200, on: ["t1"]), package: source.url,
            origin: PackageID(lockFileOf: source.url))
    }

    func add(to store: URL, named name: String = "Sting") throws(EditFailure<PasteError>) -> BinItemID {
        try Favorites.add(
            clipboard, from: source.url, named: name, bin: nil, store: store, log: { favoritesJournal(source.folder) })
    }

    @Test(arguments: [(44_100, Frames(109), Frames(48_000)), (48_000, Frames(100), Frames(44_100))])
    func addConvertsIntoStore(rate: Int, start: Frames, length: Frames) throws {
        let fixture = try FavoritesTests(rate: rate)
        let store = fixture.source.folder.url.appending(path: "Favorites.dirigible")
        let before = try packageBytes(fixture.source.url)

        let id = try fixture.add(to: store)

        let read = try Session(contentsOf: store)
        #expect(read.sampleRate == 48_000)
        #expect(read.bins.map(\.name) == ["Favorites"], "the first add makes the bin Favorites")
        let item = try #require(read.bins.flatMap(\.items).first { $0.id == id }, "the returned ID is stored")
        let clip = try #require(item.lanes.first?.clips.first)
        #expect((clip.start, clip.length) == (start, length), "\(clip.start) \(clip.length)")
        #expect(try clipNames(store) == ["host.wav"])
        let wav = try AVAudioFile(forReading: store.appending(path: "\(clipsFolderName)/host.wav"))
        #expect(wav.fileFormat.sampleRate == 48_000)
        if rate == 48_000 {
            let copied = try packageBytes(store)["\(clipsFolderName)/host.wav"]
            #expect(copied == before["\(clipsFolderName)/host.wav"], "a store-rate file copies with no conversion")
        }
        #expect(try packageBytes(fixture.source.url) == before, "the source does not change")
    }

    @Test func pasteCopiesIntoTarget() throws {
        let store = source.folder.url.appending(path: "Favorites.dirigible")
        let id = try add(to: store)
        let target = try MixPackage(name: "B")
        try target.addFile("host", channels: [[Float](repeating: 0, count: 4_800)])
        try target.session.addTrack("u1", name: "u1", layout: .mono)
        FileManager.default.createFile(atPath: target.url.appending(path: ".lock").path, contents: nil)
        let favorite = Clipboard(
            try Session(contentsOf: store).excerpt(of: id), package: store, origin: PackageID(lockFileOf: store))

        let pasted = try pasteClipboard(
            favorite, from: store, into: target.session, in: target.url,
            identity: PackageID(lockFileOf: target.url), mode: .over(at: 0), on: .tracks(["u1"]), freeBytes: { .max })
        try pasted.session.write(to: target.url)
        try FileManager.default.removeItem(at: store)

        let read = try Session(contentsOf: target.url)
        #expect(try clipNames(target.url) == ["host 2.wav", "host.wav"], "a new WAV under the stem rule")
        let clip = try #require(read.clip(pasted.clips[0])?.clip)
        #expect(read.files[clip.file]?.path == "host 2.wav")
        #expect(read.files.values.allSatisfy { !$0.path.hasPrefix("/") && !$0.path.contains("..") })
        #expect(try checkMedia(read, package: target.url).isEmpty, "every file is whole with no store")
    }

    @Test func lockedOrDamagedStoreUnchanged() throws {
        let store = source.folder.url.appending(path: "Favorites.dirigible")
        _ = try add(to: store)
        let made = try packageBytes(store)
        #expect(made["session.xml"] != nil && made["\(clipsFolderName)/host.wav"] != nil, "the first add wrote")
        let again = { () throws(EditFailure<PasteError>) in try add(to: store) }

        do {
            let held = try PackageLock(store)
            guard case .file(.locked) = refusal(of: again) else {
                Issue.record("an add under another lock holder is refused as locked")
                return
            }
            withExtendedLifetime(held) {}
        }
        #expect(try packageBytes(store) == made, "the held store keeps its bytes")

        try Data("not a session".utf8).write(to: store.appending(path: "session.xml"))
        let damaged = try packageBytes(store)
        guard case .file(.malformedXML) = refusal(of: again) else {
            Issue.record("a damaged store is refused as malformed")
            return
        }
        #expect(try packageBytes(store) == damaged, "the damaged store keeps its bytes")
    }

    @Test func folderWithNoSessionAcceptsAdd() throws {
        let store = source.folder.url.appending(path: "Favorites.dirigible")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)

        let id = try add(to: store)

        let read = try Session(contentsOf: store)
        #expect(read.sampleRate == 48_000)
        #expect(read.bins.flatMap(\.items).map(\.id) == [id])
    }

    @Test func missingParentFolderAcceptsAdd() throws {
        let store = source.folder.url.appending(path: "Support/com.delineas.dirigible/Favorites.dirigible")

        let id = try add(to: store)

        #expect(try Session(contentsOf: store).bins.flatMap(\.items).map(\.id) == [id])
    }

    /// C18: each edit reads the store under the lock, so a remove from a list read before an add keeps
    /// that add; a remove of an item that is gone changes no byte.
    @Test func staleRemoveKeepsAdd() throws {
        let store = source.folder.url.appending(path: "Favorites.dirigible")
        let first = try add(to: store, named: "First")
        let panel = try Session(contentsOf: store)
        let second = try add(to: store, named: "Second")

        let stale = try #require(panel.bins.first?.items.first?.id)
        let log = { favoritesJournal(source.folder) }
        try Favorites.edit(store: store, log: log) { session throws(SessionError) in try session.removeItem(stale) }

        #expect(try Session(contentsOf: store).bins.flatMap(\.items).map(\.id) == [second])
        let after = try packageBytes(store)
        do throws(EditFailure<SessionError>) {
            try Favorites.edit(store: store, log: log) { session throws(SessionError) in try session.removeItem(first) }
            Issue.record("a remove of a removed item is refused")
        } catch {
            guard case .body(.unknownBinItem(first)) = error else {
                Issue.record("\(error)")
                return
            }
        }
        #expect(try packageBytes(store) == after, "the refused remove changes no byte")
    }
}

/// The error of `body`, or nil when it returns.
func refusal<Value, Failure: Error>(of body: () throws(Failure) -> Value) -> Failure? {
    do throws(Failure) {
        _ = try body()
        return nil
    } catch {
        return error
    }
}

/// A journal in `folder` for the edit step; it starts only when the step logs a fault.
func favoritesJournal(_ folder: TemporaryFolder) -> DiagnosticLog {
    DiagnosticLog.start(.cli, folder: folder.url.appending(path: "Logs"), version: "0", commit: "test")
}

/// The bytes of `session.xml` and of each item of `Clips/`, hidden temporary files too, by their path.
func packageBytes(_ package: URL) throws -> [String: Data] {
    var bytes: [String: Data] = [:]
    let xml = package.appending(path: "session.xml")
    if let data = FileManager.default.contents(atPath: xml.path) { bytes["session.xml"] = data }
    for name in (try? clipNames(package)) ?? [] {
        bytes["\(clipsFolderName)/\(name)"] = FileManager.default.contents(
            atPath: package.appending(path: "\(clipsFolderName)/\(name)").path)
    }
    return bytes
}

/// The sorted names in `Clips/` of `package`, hidden names too.
func clipNames(_ package: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: package.appending(path: clipsFolderName).path).sorted()
}
