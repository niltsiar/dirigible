import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The unarchive step of a CLI or MCP write job (decision 0072, run criteria C9 and C10): what it
/// converts and saves, its order in `editPackageCore`, a fault before its save, and a damaged FLAC.
struct ArchiveStepTests {
    let fixture: ArchiveFixture
    var session = Session(sampleRate: ArchiveFixture.rate)
    let marker = Marker(id: "m1", name: "Note", position: 100, kind: .marker)

    /// An archived package with the pool files `a.wav` and `b.wav`, each as its FLAC.
    init() throws {
        fixture = try ArchiveFixture()
        try session.addFile(try fixture.addWAV("a.wav", seed: 1))
        try session.addFile(try fixture.addWAV("b.wav", seed: 2))
        _ = try fixture.save(session)
        _ = try archivePackage(&session, in: fixture.package, save: fixture.save)
        try #require(try fixture.names() == ["a.flac", "b.flac"])
    }

    func step(
        _ edited: inout Session, before: Session, seams: ArchiveSeams = ArchiveSeams()
    ) throws -> [String] {
        var lines: [String] = []
        try PackageLock.withLock(fixture.package, locked: ArchiveFault.file) { lock throws(ArchiveFault) in
            try unarchiveForWrite(
                &edited, before: before, in: fixture.package, under: lock, log: { lines.append($0) }, seams: seams)
        }
        return lines
    }

    /// The edit drops `b.wav` and adds a marker. The step converts both FLACs, saves the session of
    /// before with no attribute and no backup, and leaves the edit in memory for the save of the
    /// caller. Fail value: a step that converts only the files of the edit leaves `b.flac`.
    @Test func theStepSavesTheSessionOfBeforeWithNoAttributeAndNoBackup() throws {
        var edited = session
        try edited.removeFile("b.wav")
        try edited.setMarker(marker)

        let lines = try step(&edited, before: session)

        #expect(try fixture.names() == ["a.wav", "b.wav"])
        #expect(try holdsTheFactsOfBefore(fixture.stored()), "with no attribute")
        #expect(!FileManager.default.fileExists(atPath: fixture.url(backupsFolderName).path), "no backup")
        #expect(edited.archive == nil && Array(edited.markers.keys) == ["m1"] && edited.files["b.wav"] == nil)
        #expect(!lines.isEmpty && lines.allSatisfy { $0.hasPrefix("unarchive: ") }, "\(lines)")
    }

    /// A fault after the last file and before the save of the step leaves the attribute and every
    /// pool file a WAV; the next step saves the session with no attribute.
    @Test func aFaultBeforeTheStepSaveKeepsTheAttribute() throws {
        var edited = session
        var seams = ArchiveSeams()
        seams.after = { $0 != .converted }

        #expect(throws: ArchiveFault.cancelled) { try step(&edited, before: session, seams: seams) }

        #expect(try fixture.names() == ["a.wav", "b.wav"])
        #expect(try fixture.stored().archive == .flac)
        _ = try step(&edited, before: try fixture.stored())
        #expect(try fixture.stored().archive == nil)
    }

    /// The pool and the markers of the fixture, and no attribute.
    func holdsTheFactsOfBefore(_ stored: Session) -> Bool {
        stored.archive == nil && stored.markers.isEmpty && Set(stored.files.keys) == ["a.wav", "b.wav"]
    }

    /// A FLAC with no attribute is a kept damaged file (U41): the step changes no file.
    @Test func aPackageWithNoAttributeGetsNoStep() throws {
        var working = session
        working.archive = nil
        _ = try fixture.save(working)
        let flacs = try fixture.contents(of: ["Clips/a.flac", "Clips/b.flac"])
        var edited = working

        let lines = try step(&edited, before: working)

        #expect(lines.isEmpty)
        #expect(try fixture.contents(of: ["Clips/a.flac", "Clips/b.flac"]) == flacs)
    }

    /// A FLAC cut to half its bytes stays, the step writes its line, and the edit goes on.
    @Test func theStepKeepsADamagedFLACAndNamesIt() throws {
        let flac = fixture.url("Clips/b.flac")
        let whole = try Data(contentsOf: flac)
        try whole.prefix(whole.count / 2).write(to: flac)
        let damaged = try Data(contentsOf: flac)
        var edited = session

        let lines = try step(&edited, before: session)

        #expect(try fixture.names() == ["a.wav", "b.flac"])
        #expect(try Data(contentsOf: flac) == damaged)
        #expect(try fixture.stored().archive == nil && edited.archive == nil)
        let line = try #require(lines.first { $0.hasPrefix("damaged, kept as FLAC: ") }, "\(lines)")
        #expect(line.hasPrefix("damaged, kept as FLAC: Clips/b.flac, ") && line.hasSuffix(" of 30000 frames decoded"))
    }

    func edit<Failure: Error>(
        touchesClips: Bool, writeUnchanged: Bool = true,
        _ body: (inout Session, PackageLock) throws(Failure) -> Void
    ) throws(EditFailure<Failure>) {
        try editPackageCore(
            fixture.package, ripple: false, touchesClips: touchesClips, writeUnchanged: writeUnchanged,
            log: { .disabled }, body)
    }

    /// A body that opens no clip file runs first: a refused body and a body that changes nothing
    /// leave each FLAC and the attribute. Fail value: a step before the body converts the files.
    @Test func aRefusedOrUnchangedEditKeepsEveryFLAC() throws {
        let file = try fixture.sessionFile()
        let flacs = try fixture.contents(of: ["Clips/a.flac", "Clips/b.flac"])

        #expect(throws: EditFailure<SessionError>.self) {
            try edit(touchesClips: false) { session, _ throws(SessionError) in try session.removeMarker("none") }
        }
        try edit(touchesClips: false, writeUnchanged: false) { _, _ throws(SessionError) in }

        #expect(try fixture.sessionFile() == file)
        #expect(try fixture.contents(of: ["Clips/a.flac", "Clips/b.flac"]) == flacs)
    }

    /// An edit of a package that a body sees after the step: each pool file is a WAV while the body
    /// runs, and a fault of the body leaves the package unarchived with the facts of before.
    @Test func aClipBodyRunsAfterTheStep() throws {
        var seen: [String] = []
        #expect(throws: EditFailure<SessionError>.self) {
            try edit(touchesClips: true) { session, _ throws(SessionError) in
                seen = (try? fixture.names()) ?? []
                try session.setMarker(marker)
                try session.removeMarker("none")
            }
        }

        #expect(seen == ["a.wav", "b.wav"])
        #expect(try holdsTheFactsOfBefore(fixture.stored()))
    }

    /// The step of an edit saves with no backup, and the save of the edit keeps the due backup:
    /// it holds the facts of before and no attribute.
    @Test func theDueBackupOfAnEditHasNoAttribute() throws {
        try edit(touchesClips: false) { session, _ throws(SessionError) in try session.setMarker(marker) }

        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.url(backupsFolderName).path)
        #expect(names.count == 1)
        let backup = try String(
            contentsOf: fixture.url("\(backupsFolderName)/\(try #require(names.first))"), encoding: .utf8)
        #expect(!backup.contains("archive=") && !backup.contains("\"Note\""), Comment(rawValue: backup))
        #expect(try Array(fixture.stored().markers.keys) == ["m1"] && fixture.stored().archive == nil)
    }
}
