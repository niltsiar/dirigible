import Foundation
import Testing

@testable import DirigibleCore

/// A package from another person can hold a link or a special item. The open refuses it, and the
/// prune scan checks `Clips/` and `Transcripts/` again, so no read or move leaves the package.
struct PackageItemsTests {
    let folder: URL
    let package: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "PackageItemsTests-\(UUID().uuidString)")
        package = folder.appending(path: "Show.dirigible")
        try Session(sampleRate: 48_000).write(to: package)
    }

    /// A top-level item of the package and a kind that it must not have.
    struct WrongItem: Sendable, CustomTestStringConvertible {
        enum Kind: Sendable { case linkToAFolder, file, linkToASession, fifo, linkToAFile, hardLink }
        let name: String
        let kind: Kind
        var testDescription: String { "\(name) \(kind)" }

        static let all =
            ["Clips", "Transcripts", "Backups", "Artwork", "Capture"].flatMap {
                [WrongItem(name: $0, kind: .linkToAFolder), WrongItem(name: $0, kind: .file)]
            } + [
                WrongItem(name: "session.xml", kind: .linkToASession), WrongItem(name: "session.xml", kind: .fifo),
                WrongItem(name: ".lock", kind: .linkToAFile), WrongItem(name: ".lock", kind: .hardLink),
            ]
    }

    /// C14. A link can name a folder or a file outside the package, a FIFO blocks a read, and a hard
    /// link can name the lock of another package.
    @Test(arguments: WrongItem.all)
    func eachItemThatIsNotItsKindIsRefused(_ item: WrongItem) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = package.appending(path: item.name)
        let xml = try Data(contentsOf: package.appending(path: "session.xml"))
        try? FileManager.default.removeItem(at: url)
        switch item.kind {
        case .linkToAFolder:
            let elsewhere = folder.appending(path: "Elsewhere")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: elsewhere)
        case .file: try Data("x".utf8).write(to: url)
        case .linkToASession:
            let other = folder.appending(path: "other.xml")
            try xml.write(to: other)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
        case .fifo: try #require(mkfifo(url.path, 0o644) == 0)
        case .linkToAFile:
            let other = folder.appending(path: "Other.lock")
            try Data().write(to: other)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
        case .hardLink:
            let other = folder.appending(path: "Other.lock")
            try Data().write(to: other)
            try #require(link(other.path, url.path) == 0)
        }

        #expect(throws: SessionFileError.unsafeItem(item.name)) { try Session(contentsOf: package) }
    }

    /// An entry of `Artwork/`, `Capture/`, or `Backups/` and its wrong kind, with the error of the open.
    struct WrongEntry: Sendable, CustomTestStringConvertible {
        enum Kind: Sendable { case artworkLink, anchorLink, anchorFIFO, backupLink, artworkFolder, artworkMode000 }
        let kind: Kind
        let error: SessionFileError
        var testDescription: String { "\(kind)" }

        static let artwork = "0F0E0D0C-0B0A-4908-8706-050403020100.jpg"
        static let all = [
            WrongEntry(kind: .artworkLink, error: .unsafeItem("Artwork/\(artwork)")),
            WrongEntry(kind: .anchorLink, error: .unsafeItem("Capture/take1.anchor")),
            WrongEntry(kind: .anchorFIFO, error: .unsafeItem("Capture/take1.anchor")),
            WrongEntry(kind: .backupLink, error: .unsafeItem("Backups/session-20011009T081530.250Z.xml")),
            WrongEntry(kind: .artworkFolder, error: .unsafeItem("Artwork/Inner")),
            WrongEntry(kind: .artworkMode000, error: .readFailed(errno: EACCES)),
        ]
    }

    /// C14. The premortem layout: `session.xml` names an artwork that is a link to a local file, so an
    /// export would put that file into the episode. A link in `Capture/` or `Backups/` makes a
    /// recovery or a revert read a local file. A folder that does not list hides its entries.
    @Test(arguments: WrongEntry.all)
    func eachEntryThatIsNotAFileIsRefused(_ entry: WrongEntry) throws {
        let artwork = package.appending(path: "Artwork")
        defer {
            chmod(artwork.path, 0o755)
            try? FileManager.default.removeItem(at: folder)
        }
        for name in ["Artwork", "Capture", "Backups"] {
            try FileManager.default.createDirectory(
                at: package.appending(path: name), withIntermediateDirectories: false)
        }
        let canary = folder.appending(path: "canary.txt")
        try Data("canary text of PackageItemsTests".utf8).write(to: canary)
        let anchor = package.appending(path: "Capture/take1.anchor")
        switch entry.kind {
        case .artworkLink:
            var session = Session(sampleRate: 48_000)
            var episode = Episode()
            episode.artwork = try ArtworkName(WrongEntry.artwork)
            session.setEpisode(episode)
            try session.write(to: package)
            try FileManager.default.createSymbolicLink(
                at: artwork.appending(path: WrongEntry.artwork), withDestinationURL: canary)
        case .anchorLink: try FileManager.default.createSymbolicLink(at: anchor, withDestinationURL: canary)
        case .anchorFIFO: try #require(mkfifo(anchor.path, 0o644) == 0)
        case .backupLink:
            let other = folder.appending(path: "other.xml")
            try Data(contentsOf: package.appending(path: "session.xml")).write(to: other)
            try FileManager.default.createSymbolicLink(
                at: package.appending(path: "Backups/session-20011009T081530.250Z.xml"), withDestinationURL: other)
        case .artworkFolder:
            try FileManager.default.createDirectory(
                at: artwork.appending(path: "Inner"), withIntermediateDirectories: false)
        case .artworkMode000: try #require(chmod(artwork.path, 0o000) == 0)
        }

        #expect(throws: entry.error) { try Session(contentsOf: package) }
    }

    /// The audit input `prune-escape/`: `Clips` is a link to `../victim`, and the pool entry
    /// `notes.txt` has no clip. Returns the victim folder and the bytes of its files by name.
    func pruneEscape() throws -> (victim: URL, files: [String: Data]) {
        let victim = folder.appending(path: "victim")
        let files = ["notes.txt": Data("victim notes".utf8), "old.wav": Data("RIFF".utf8)]
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false)
        for (name, data) in files { try data.write(to: victim.appending(path: name)) }
        try FileManager.default.removeItem(at: package.appending(path: "Clips"))
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <session xmlns="https://github.com/niltsiar/dirigible/session" version="12" sampleRate="48000">
              <files>
                <file id="f1" path="notes.txt" channels="1" length="1"/>
              </files>
            </session>

            """.utf8
        ).write(to: package.appending(path: "session.xml"))
        try FileManager.default.createSymbolicLink(
            atPath: package.appending(path: "Clips").path, withDestinationPath: "../victim")
        return (victim, files)
    }

    /// The bytes of each file in `folder`, by name.
    static func bytes(in folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            result[name] = try Data(contentsOf: folder.appending(path: name))
        }
        return result
    }

    /// C15. Through the trash seam with a function that records each URL and moves no file: the
    /// open refuses the package, so the trash function gets no file of the link target.
    @Test func aClipsLinkSendsNothingToTheTrash() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (victim, files) = try pruneEscape()
        var trashed: [URL] = []
        var refusal: (any Error)?

        do {
            var session = try Session(contentsOf: package)
            let scan = try UnusedFiles(scanning: session, keptBy: [], soleCopies: [], in: package)
            _ = try scan.prune(
                &session, save: { (_: Session) throws(SessionFileError) -> URL in package },
                trash: { url in
                    trashed.append(url)
                    return url
                })
        } catch {
            refusal = error
        }

        #expect(trashed.isEmpty, "trashed: \(trashed.map { $0.resolvingSymlinksInPath().path })")
        #expect(refusal as? SessionFileError == .unsafeItem("Clips"), "\(String(describing: refusal))")
        #expect(try Self.bytes(in: victim) == files)
    }

    /// C16(a). The scan runs long after the open, and a listing follows a folder that became a link.
    /// For `Clips/`, the target holds an unused pool path; for `Transcripts/`, a transcript file name.
    @Test(arguments: ["Clips", "Transcripts"])
    func aScanRefusesAFolderThatBecameALink(_ name: String) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = try UnusedFilesTests.session([("f1", "notes.txt")])
        try session.write(to: package)
        let opened = try Session(contentsOf: package)
        let victim = folder.appending(path: "victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false)
        try Data("victim notes".utf8).write(to: victim.appending(path: "notes.txt"))
        try Data("x".utf8).write(to: victim.appending(path: "\(UUID().uuidString).xml"))
        let files = try Self.bytes(in: victim)
        try? FileManager.default.removeItem(at: package.appending(path: name))
        try FileManager.default.createSymbolicLink(
            atPath: package.appending(path: name).path, withDestinationPath: "../victim")

        let expected: UnusedFilesError =
            name == "Clips" ? .clipsUnreadable(errno: ENOTDIR) : .transcriptsUnreadable(errno: ENOTDIR)
        #expect(throws: expected) {
            try UnusedFiles(scanning: opened, keptBy: [], soleCopies: [], in: package)
        }
        #expect(try Self.bytes(in: victim) == files)
    }

    /// Moves the folder `name` of the package to `<name>-target` beside it and puts a link there.
    func swapForALink(_ name: String) throws -> URL {
        let target = folder.appending(path: "\(name)-target")
        try FileManager.default.moveItem(at: package.appending(path: name), to: target)
        try FileManager.default.createSymbolicLink(
            atPath: package.appending(path: name).path, withDestinationPath: "../\(name)-target")
        return target
    }

    /// C16(b). The save of an open window writes `session.xml` in the folder of the lock. Its new
    /// transcript file goes into the link target with a new name, so no existing file changes.
    @Test func aSaveAfterAFolderSwapKeepsTheSession() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try UnusedFilesTests.transcribed().write(to: package)
        var session = try Session(contentsOf: package)
        let lock = try PackageLock(package)
        _ = try swapForALink("Clips")
        let transcripts = try swapForALink("Transcripts")
        let before = try Self.bytes(in: transcripts)

        try session.removeClips(["c-g"])
        try session.removeFile("g")
        let saved = try session.write(under: lock)

        #expect(saved.resolvingSymlinksInPath() == package.resolvingSymlinksInPath())
        var read = try Session(xml: Data(contentsOf: package.appending(path: "session.xml")))
        read.loadTranscripts(from: package)
        #expect(read == session)
        let after = try Self.bytes(in: transcripts)
        #expect(before.allSatisfy { after[$0.key] == $0.value }, "each old transcript file keeps its bytes")
        let file = try #require(session.transcripts[TranscriptID(1)]?.file)
        #expect(Set(after.keys).subtracting(before.keys) == ["\(file).xml"])
    }

    /// C16(c). A swap between the scan and the move: the item gets `.replaced`, and the file of the
    /// link target stays.
    @Test func aSwapAfterTheScanMovesNothing() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var session = try UnusedFilesTests.session([("f1", "spare.wav")])
        try session.write(to: package)
        try Data(count: 4).write(to: package.appending(path: "Clips/spare.wav"))
        let scan = try UnusedFiles(scanning: session, keptBy: [], soleCopies: [], in: package)
        #expect(scan.items.map(\.path) == ["spare.wav"])
        try FileManager.default.removeItem(at: package.appending(path: "Clips"))
        let victim = folder.appending(path: "victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false)
        try Data("victim wav".utf8).write(to: victim.appending(path: "spare.wav"))
        try FileManager.default.createSymbolicLink(
            atPath: package.appending(path: "Clips").path, withDestinationPath: "../victim")
        var trashed: [URL] = []

        let report = try scan.prune(
            &session, save: { (_: Session) throws(SessionFileError) -> URL in package },
            trash: { url in
                trashed.append(url)
                return url
            })

        #expect(report.failed.map(\.fault) == [.replaced] && report.moved.isEmpty && trashed.isEmpty)
        #expect(try Data(contentsOf: victim.appending(path: "spare.wav")) == Data("victim wav".utf8))
    }
}
