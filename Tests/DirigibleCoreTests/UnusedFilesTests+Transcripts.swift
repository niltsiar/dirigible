import Foundation
import Testing

@testable import DirigibleCore

/// Decision 0055: Remove Unused Files lists each file in `Transcripts/` that no holder names (run
/// transcript-1, criterion T14).
extension UnusedFilesTests {
    var transcripts: URL { package.appending(path: "Transcripts") }

    /// Files "h" and "g" with a clip each, and transcript 1 with words in both.
    static func transcribed() throws -> Session {
        var session = try session([("h", "h.wav"), ("g", "g.wav")], used: ["h", "g"])
        session.addWords([(1, 0..<100, "one")], file: "h")
        session.addWords([(2, 0..<100, "two")], file: "g")
        return session
    }

    /// `session` saved, then saved again after a prune of file "g": the words of transcript 1 get
    /// a new file. Returns the session after the prune and the old session.
    func prunedTwice() throws -> (session: Session, old: Session) {
        let old = try Self.transcribed()
        try old.write(to: package)
        var session = old
        try session.removeClips(["c-g"])
        try session.removeFile("g")
        try session.write(to: package)
        return (session, old)
    }

    func path(_ session: Session) throws -> String {
        "Transcripts/\(try #require(session.transcripts[TranscriptID(1)]?.file)).xml"
    }

    /// T14. After a prune of a file with words, only the old transcript file is listed.
    @Test func anOrphanTranscriptFileIsListed() throws {
        let (session, old) = try prunedTwice()
        let scan = try scan(session)
        #expect(Self.paths(scan) == [try path(old)])
        let name = try #require(old.transcripts[TranscriptID(1)]?.file)
        #expect(scan.items.map(\.kind) == [.transcript(name)] && scan.items[0].bytes > 0)
    }

    /// The bytes of the transcript file of `session`.
    func bytes(_ session: Session) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: package.appending(path: path(session)).path)
        return try #require((attributes[.size] as? NSNumber)?.int64Value)
    }

    /// A backup keeps the file, and the kept line counts it with its size.
    @Test func aBackupKeepsItsTranscriptFile() throws {
        let (session, old) = try prunedTwice()
        try backup(old)
        let scan = try scan(session)
        #expect(scan.items.isEmpty)
        #expect(scan.kept == UnusedFiles.Kept(count: 1, bytes: try bytes(old)))
    }

    @Test func anUndoEntryKeepsItsTranscriptFile() throws {
        let (session, old) = try prunedTwice()
        let scan = try scan(session, keptBy: [old])
        #expect(scan.items.isEmpty)
        #expect(scan.kept == UnusedFiles.Kept(count: 1, bytes: try bytes(old)))
    }

    /// The file of the session is not a kept file, also when a keeper names it too.
    @Test func theOwnTranscriptFileIsNotKept() throws {
        let (session, _) = try prunedTwice()
        #expect(try scan(session, keptBy: [session]).kept == UnusedFiles.Kept(count: 0, bytes: 0))
    }

    /// A transcript that did not load holds its file, so a damaged file never moves.
    @Test func aNotLoadedTranscriptKeepsItsFile() throws {
        let session = try Self.transcribed()
        try session.write(to: package)
        try Data("damaged".utf8).write(to: package.appending(path: try path(session)))
        let opened = try Session(contentsOf: package)
        #expect(opened.transcriptsNotLoaded.map(\.id) == [TranscriptID(1)])
        #expect(try scan(opened).items.isEmpty)
    }

    /// T14. The prune moves the orphan file to the Trash from the package, not from `Clips/`.
    @Test func aPruneMovesTheTranscriptFileToTheTrash() throws {
        var (session, old) = try prunedTwice()
        var trashed: [String] = []
        let report = try scan(session).prune(&session, save: save) { url in
            trashed.append(url.path)
            return Self.fakeTrashURL(url)
        }
        #expect(trashed == [package.appending(path: try path(old)).path])
        #expect(report.moved.map(\.item.path) == [try path(old)] && report.failed.isEmpty)
    }

    /// An old package has no `Transcripts/` folder: the scan gives no transcript item.
    @Test func noTranscriptsFolderGivesNoItem() throws {
        #expect(!FileManager.default.fileExists(atPath: transcripts.path))
        #expect(try scan(Self.transcribed()).items.isEmpty)
    }

    /// Only a regular file `<canonical UUID>.xml` is an item: a `notes.xml`, a lower-case UUID
    /// name, a link, and a folder stay.
    @Test func onlyTranscriptFileNamesAreListed() throws {
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        let orphan = UUID().uuidString + ".xml"
        for name in ["notes.xml", UUID().uuidString.lowercased() + ".xml", orphan] {
            try Data("x".utf8).write(to: transcripts.appending(path: name))
        }
        try FileManager.default.createSymbolicLink(
            at: transcripts.appending(path: UUID().uuidString + ".xml"),
            withDestinationURL: package.appending(path: "session.xml"))
        try FileManager.default.createDirectory(
            at: transcripts.appending(path: UUID().uuidString + ".xml"), withIntermediateDirectories: false)
        #expect(Self.paths(try scan(Self.session([]))) == ["Transcripts/" + orphan])
    }

    /// A `Transcripts` that is not a folder stops the scan: an error never reads as no file.
    @Test func anUnreadableTranscriptsFolderThrows() throws {
        try Data("x".utf8).write(to: transcripts)
        #expect(throws: UnusedFilesError.transcriptsUnreadable(errno: ENOTDIR)) { try scan(Self.session([])) }
    }
}
