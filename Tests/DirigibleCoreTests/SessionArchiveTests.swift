import Foundation
import Testing

@testable import DirigibleCore

/// The archive state of a session (decision 0072): its version rules (0024 P3, P6, P7), undo and
/// revert, the name on disk of a pool file, and the leftover files of a crashed conversion.
struct SessionArchiveTests {
    let files = SessionFileTests()

    func text(_ session: Session) throws -> String { String(decoding: try session.checkedData(), as: UTF8.self) }

    func archived(_ session: Session) -> Session {
        var session = session
        session.archive = .flac
        return session
    }

    /// C4: `archive = .flac` writes the attribute and `archiveSessionVersion`, and a build whose
    /// newest version is one lower refuses the file (P3).
    @Test func anArchivedSessionWritesTheArchiveVersion() throws {
        let session = archived(try files.fullSession())
        let data = try session.checkedData()
        let text = String(decoding: data, as: UTF8.self)

        #expect(archiveSessionVersion == binSessionVersion + 1)
        #expect(text.contains(#"archive="flac""#) && text.contains(#"version="\#(archiveSessionVersion)""#), "\(text)")
        #expect(try Session(xml: data) == session)
        #expect(throws: SessionFileError.unsupportedVersion(archiveSessionVersion)) {
            try Session(xml: data, newest: archiveSessionVersion - 1)
        }
    }

    /// C4: with no attribute the session writes the version of its other data (P6), so the
    /// unarchive gives a file that the build before the archive opens.
    @Test func aWorkingSessionWritesTheVersionOfItsData() throws {
        let plain = Session(sampleRate: 48_000)
        let full = try files.fullSession()
        for session in [plain, full] {
            var copy = archived(session)
            copy.archive = nil
            let text = try text(copy)

            #expect(copy.fileVersion == session.fileVersion && copy.fileVersion < archiveSessionVersion)
            #expect(text.contains(#"version="\#(session.fileVersion)""#) && !text.contains("archive="), "\(text)")
        }
        #expect(plain.fileVersion == 1)
    }

    /// C4: a file below `archiveSessionVersion` with the attribute is invalid, as each new attribute
    /// of 0024; a value other than `flac` is invalid too.
    @Test func anArchiveAttributeBelowItsVersionOrWithAnotherValueIsRefused() throws {
        let text = try text(archived(Session(sampleRate: 48_000)))
        let older = text.replacingOccurrences(
            of: #"version="\#(archiveSessionVersion)""#, with: #"version="\#(archiveSessionVersion - 1)""#)
        let other = text.replacingOccurrences(of: #"archive="flac""#, with: #"archive="alac""#)
        #expect(older != text && other != text)

        for bad in [older, other] {
            #expect(throws: SessionFileError.invalidValue(element: "session", attribute: "archive")) {
                try Session(xml: Data(bad.utf8))
            }
        }
        #expect(try Session(xml: Data(text.utf8)).archive == .flac)
    }

    /// C5: undo, redo, and an edit keep the current archive state, as they keep `<recording>`.
    @Test func undoKeepsTheArchiveState() throws {
        var history = History(Session(sampleRate: 48_000))
        try history.edit { try $0.addTrack("t1", name: "Host", layout: .mono) }
        var revision = history.revision
        history.edit { $0.archive = .flac }
        #expect(history.revision == revision, "a change of only the archive state records no entry")

        try history.undo()
        #expect(history.session.archive == .flac && history.session.tracks.isEmpty)
        try history.redo()
        #expect(history.session.archive == .flac && history.session.tracks.map(\.id) == ["t1"])

        revision = history.revision
        history.edit { $0.archive = nil }
        #expect(history.session.archive == nil && history.revision == revision)
        try history.undo()
        #expect(history.session.archive == nil && history.session.tracks.isEmpty)
    }

    /// C5: a revert to a backup keeps the current value: a backup with the attribute on a working
    /// session, and a backup with none on an archived session (near input).
    @Test func aRevertKeepsTheArchiveState() throws {
        // No armed `<recording>`, so the revert may remove the track (decision 0012).
        var working = Session(sampleRate: 48_000)
        try working.addTrack("t1", name: "Host", layout: .mono)
        let backupArchived = archived(Session(sampleRate: 48_000))
        let backupWorking = Session(sampleRate: 48_000)

        let toArchived = try working.reverted(to: backupArchived)
        let toWorking = try archived(working).reverted(to: backupWorking)

        #expect(toArchived.archive == nil && toArchived.tracks.isEmpty)
        #expect(toWorking.archive == .flac && toWorking.tracks.isEmpty)
    }

    /// The resolver: the WAV name while an item is there (also both files after a crash), else the
    /// FLAC name while an item is there, else the WAV name. It reads the item with `lstat`, so a
    /// link counts as an item.
    @Test func poolFileNameGivesTheNameOnDisk() throws {
        let clips = files.package.appending(path: "Clips")
        try FileManager.default.createDirectory(
            at: clips.appending(path: "imported"), withIntermediateDirectories: true)
        let wav = AudioFile(id: "f1", path: "imported/a.wav", layout: .mono, length: 10)
        let other = AudioFile(id: "f2", path: "b.aiff", layout: .mono, length: 10)
        func touch(_ name: String) {
            FileManager.default.createFile(atPath: clips.appending(path: name).path, contents: Data("x".utf8))
        }

        #expect(poolFileName(wav, in: files.package) == PoolFileName(name: "Clips/imported/a.wav", form: .pool))
        #expect(poolFileName(other, in: files.package) == PoolFileName(name: "Clips/b.aiff", form: .pool))
        touch("imported/a.flac")
        #expect(poolFileName(wav, in: files.package) == PoolFileName(name: "Clips/imported/a.flac", form: .flac))
        touch("imported/a.wav")
        #expect(poolFileName(wav, in: files.package) == PoolFileName(name: "Clips/imported/a.wav", form: .pool))
        try FileManager.default.removeItem(at: clips.appending(path: "imported/a.wav"))
        try FileManager.default.createSymbolicLink(
            atPath: clips.appending(path: "imported/a.wav").path, withDestinationPath: "missing.wav")
        #expect(poolFileName(wav, in: files.package) == PoolFileName(name: "Clips/imported/a.wav", form: .pool))
    }

    /// C10: a crash during a conversion leaves `Clips/.<name>.archive-<UUID>.tmp`; the next locked
    /// entry removes it. A name with no leading "." stays (near input).
    @Test func removeTemporaryFilesDeletesTheLeftoverOfAConversion() throws {
        let session = try files.fullSession()
        try session.write(to: files.package)
        let clips = files.package.appending(path: "Clips")
        let uuid = UUID()
        let leftovers = [archiveTemporaryName(of: "t1-1-1.flac", uuid), archiveTemporaryName(of: "t2-1-1.wav", uuid)]
        let kept = ["t1-1-1.archive-\(uuid.uuidString).tmp", "t1-1-1.flac"]
        for name in leftovers + kept {
            FileManager.default.createFile(atPath: clips.appending(path: name).path, contents: Data("x".utf8))
        }

        session.removeTemporaryFiles(in: files.package)

        #expect(try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted() == kept.sorted())
    }
}
