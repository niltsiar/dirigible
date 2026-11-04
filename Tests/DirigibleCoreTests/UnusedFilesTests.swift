import Foundation
import Testing

@testable import DirigibleCore

/// Decision 0047: the scan of the clip files that no clip uses (criteria C1 to C6 and C5b of run
/// `2026-10-12-remove-unused-files`). Each test makes its own package; the on-disk `session.xml`
/// is the empty session of `Session.write(to:)` unless a test writes another one.
struct UnusedFilesTests {
    let package: URL
    var clips: URL { package.appending(path: "Clips") }

    init() throws {
        package = FileManager.default.temporaryDirectory
            .appending(path: "UnusedFilesTests-\(UUID().uuidString)/Episode.dirigible")
        try Session(sampleRate: 48_000).write(to: package)
    }

    /// A session with one mono track "a", a pool entry for each `(id, path)` of `files`, and one
    /// clip for each ID in `used`.
    static func session(_ files: [(FileID, String)], used: [FileID] = []) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("a", name: "A", layout: .mono)
        for (id, path) in files { try session.addFile(AudioFile(id: id, path: path, layout: .mono, length: 48_000)) }
        for (index, id) in used.enumerated() {
            let clip = Clip(
                id: ClipID("c-\(id.rawValue)"), file: id, start: Frames(index * 1_000), offset: 0, length: 1)
            try session.place(clip, on: "a")
        }
        return session
    }

    /// Writes `bytes` bytes at `path` in `Clips/`, and makes its folders.
    @discardableResult
    func plant(_ path: String, bytes: Int = 4) throws -> URL {
        let url = clips.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    /// Writes `session` as a backup in `Backups/` with the time `seconds`.
    @discardableResult
    func backup(_ session: Session, seconds: Int = 2_000_000_000) throws -> Backup {
        try backup(session.checkedData(), seconds: seconds)
    }

    @discardableResult
    func backup(_ data: Data, seconds: Int = 2_000_000_000) throws -> Backup {
        let backup = Backup(saved: Date(timeIntervalSince1970: TimeInterval(seconds)))
        let folder = package.appending(path: "Backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: backup.fileName))
        return backup
    }

    func scan(_ session: Session, keptBy keepers: [Session] = [], soleCopies: Set<String> = []) throws -> UnusedFiles {
        try UnusedFiles(scanning: session, keptBy: keepers, soleCopies: soleCopies, in: package)
    }

    static func paths(_ scan: UnusedFiles) -> [String] { scan.items.map(\.path) }

    /// C3. Pass value: an NFD disk name with an NFC pool path, a case change, and a `./` part give
    /// one pool item and no stray item. Fail value: the unrelated name `Pena.wav` is a stray.
    @Test func matchesNormalizedNames() throws {
        let nfc = "Pe\u{00F1}a.wav"
        let nfd = "Pen\u{0303}a.wav"
        let session = try Self.session(
            [("p", nfc), ("q", "./Case.wav"), ("r", "\u{00D1}u.wav")], used: ["p"])
        try plant(nfd)
        try plant("CASE.WAV")
        try plant("N\u{0303}u.wav")
        try plant("Pena.wav")

        let scan = try scan(session)

        let kinds = Set(scan.items.map(\.kind))
        #expect(kinds == [.pool("q"), .pool("r"), .stray], "items: \(scan.items)")
        #expect(scan.items.count == 3, "one item for each file: \(Self.paths(scan))")
        #expect(scan.items.first { $0.kind == .stray }?.path == "Pena.wav")
    }

    /// C1, with a pool path in a subfolder. Negative: the used file is not in the list.
    @Test func listsUnusedPoolFile() throws {
        let session = try Self.session([("u", "used.wav"), ("x", "sub/x.wav"), ("y", "y.wav")], used: ["u"])
        try plant("used.wav")
        try plant("sub/x.wav", bytes: 7)
        try plant("y.wav", bytes: 3)

        let scan = try scan(session)

        #expect(scan.items.map(\.kind) == [.pool("x"), .pool("y")])
        #expect(Self.paths(scan) == ["sub/x.wav", "y.wav"])
        #expect(scan.items.map(\.bytes) == [7, 3])
        #expect(scan.kept == UnusedFiles.Kept(count: 0, bytes: 0))
    }

    /// C2.
    @Test func listsStrayWAVOnly() throws {
        let session = try Self.session([("n", "named.wav")], used: ["n"])
        try plant("named.wav")
        try plant("stray.WAV", bytes: 5)
        try plant("notes.txt")
        try plant("sub/deep.wav")
        try FileManager.default.createDirectory(at: clips.appending(path: "dir.wav"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: clips.appending(path: "link.wav"), withDestinationURL: clips.appending(path: "notes.txt"))
        try plant(".x.wav.tmp")
        try plant(".hidden.wav")

        let scan = try scan(session)

        #expect(scan.items.map(\.kind) == [.stray])
        #expect(Self.paths(scan) == ["stray.WAV"])
        #expect(scan.items.first?.bytes == 5)
    }

    /// C5b. A pool path through a link to a folder outside `Clips/` is never an item.
    @Test func neverLeavesClips() throws {
        let outside = package.deletingLastPathComponent().appending(path: "Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(count: 4).write(to: outside.appending(path: "x.wav"))
        try FileManager.default.createSymbolicLink(at: clips.appending(path: "out"), withDestinationURL: outside)
        let session = try Self.session([("o", "out/x.wav"), ("i", "in.wav")])
        try plant("in.wav")

        let scan = try scan(session)

        #expect(Self.paths(scan) == ["in.wav"], "the scan ran, and the outside file is not an item")
    }

    /// C5b. Two pool entries name one file, and a used pool path is a link to a regular file.
    @Test func sharedFileStays() throws {
        let session = try Self.session([("a", "a.wav"), ("b", "./A.WAV"), ("l", "link.wav")], used: ["a", "l"])
        try plant("a.wav")
        try plant("real.wav")
        try FileManager.default.createSymbolicLink(
            at: clips.appending(path: "link.wav"), withDestinationURL: clips.appending(path: "real.wav"))
        try plant("other.wav")

        let scan = try scan(session)

        #expect(Self.paths(scan) == ["other.wav"])
        #expect(scan.kept.count == 0, "the session holds them, not a keeper")
    }

    /// C4.
    @Test func keepsFilesOfBackupClips() throws {
        try backup(Self.session([("b", "b.wav"), ("c", "c.wav")], used: ["b", "c"]))
        let session = try Self.session([("b", "b.wav")])
        try plant("b.wav", bytes: 10)
        try plant("c.wav", bytes: 20)

        let scan = try scan(session)

        #expect(scan.items.isEmpty, "items: \(Self.paths(scan))")
        #expect(scan.kept == UnusedFiles.Kept(count: 2, bytes: 30))
    }

    /// C4 negative: a file that only the pool of a backup names is in the list.
    @Test func listsFileOfBackupPoolOnly() throws {
        try backup(Self.session([("b", "b.wav")]))
        let session = try Self.session([("b", "b.wav")])
        try plant("b.wav")

        let scan = try scan(session)

        #expect(scan.items.map(\.kind) == [.pool("b")])
        #expect(scan.kept.count == 0)
    }

    /// C4b. The prune save can make the on-disk `session.xml` a backup. Negative: a file that only
    /// its pool names is in the list.
    @Test func keepsFilesOfDiskSession() throws {
        try Self.session([("d", "d.wav"), ("e", "e.wav")], used: ["d"]).write(to: package)
        let session = try Self.session([("d", "d.wav"), ("e", "e.wav")])
        try plant("d.wav", bytes: 6)
        try plant("e.wav")

        let scan = try scan(session)

        #expect(scan.items.map(\.kind) == [.pool("e")])
        #expect(scan.kept == UnusedFiles.Kept(count: 1, bytes: 6))
    }

    /// C5. A newer backup or a backup read errno stops the scan and names the backup.
    @Test func refusesNewerBackup() throws {
        let xml = try String(decoding: Self.session([]).checkedData(), as: UTF8.self)
        let newer = xml.replacing(/version="\d+"/, with: "version=\"99\"")
        let backup = try backup(Data(newer.utf8))
        let session = try Self.session([("b", "b.wav")])
        try plant("b.wav")

        #expect(throws: UnusedFilesError.backupUnreadable(backup, .unsupportedVersion(99))) {
            try scan(session)
        }

        let url = package.appending(path: "Backups").appending(path: backup.fileName)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: UnusedFilesError.backupUnreadable(backup, .readFailed(errno: EISDIR))) {
            try scan(session)
        }
    }

    /// C5. A damaged backup keeps no file, and the scan names it.
    @Test func damagedBackupKeepsNothing() throws {
        let backup = try backup(Data("<session file=\"b.wav\"".utf8))
        let session = try Self.session([("b", "b.wav")])
        try plant("b.wav")

        let scan = try scan(session)

        #expect(scan.items.map(\.kind) == [.pool("b")])
        #expect(scan.damagedBackups == [backup])
    }

    /// C6. An undo entry holds h.wav and a redo entry holds r.wav. Negative: z.wav, which only
    /// the pool of each entry names, is in the list.
    @Test func keepsFilesOfHistoryEntries() throws {
        var history = History(try Self.session([("h", "h.wav"), ("r", "r.wav"), ("z", "z.wav")], used: ["h"]))
        try history.edit { try $0.removeClips(["c-h"]) }
        try history.edit { try $0.place(Clip(id: "c-r", file: "r", start: 0, offset: 0, length: 1_000), on: "a") }
        try history.undo()
        try plant("h.wav", bytes: 2)
        try plant("r.wav", bytes: 3)
        try plant("z.wav")

        let scan = try scan(history.session, keptBy: history.entries)

        #expect(scan.items.map(\.kind) == [.pool("z")])
        #expect(scan.kept == UnusedFiles.Kept(count: 2, bytes: 5))
    }

    /// Review item 5: a listed backup that is gone at its read (here a dangling link, as a backup
    /// that an autosave deletes during the scan) does not block the scan.
    @Test func goneBackupDoesNotBlock() throws {
        let folder = package.appending(path: "Backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let gone = Backup(saved: Date(timeIntervalSince1970: 2_000_000_000))
        try FileManager.default.createSymbolicLink(
            atPath: folder.appending(path: gone.fileName).path, withDestinationPath: "/missing-\(UUID().uuidString)")
        try plant("s.wav")

        let scan = try scan(Self.session([]))

        #expect(Self.paths(scan) == ["s.wav"] && scan.damagedBackups.isEmpty)
    }

    /// Review item 6: a pool entry that is a symbolic link to a file outside the package is no
    /// candidate. The scan names it.
    @Test func linkedPoolFileIsNoCandidate() throws {
        let outside = package.deletingLastPathComponent().appending(path: "outside.wav")
        try Data(count: 4).write(to: outside)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: clips.appending(path: "ext.wav"), withDestinationURL: outside)

        let scan = try scan(Self.session([("e", "ext.wav")]))

        #expect(scan.items.isEmpty && scan.notFiles == ["ext.wav"])
    }
}
