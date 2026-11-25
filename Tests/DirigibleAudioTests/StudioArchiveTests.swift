import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A package with tracks t1 and t2 and three 24-bit pool WAVs: f1 and f2 on the tracks, f3 in the
/// pool only. The archive converts each of them.
struct ArchiveStudioFixture {
    let package: MixPackage
    var url: URL { package.url }

    @concurrent nonisolated static func make() async throws -> sending ArchiveStudioFixture {
        let package = try MixPackage()
        for (index, id) in (["f1", "f2", "f3"] as [FileID]).enumerated() {
            try package.addFile(id, channels: [sine(seconds: 1, rate: 48_000, frequency: 440 * Double(index + 1))])
        }
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 48_000)
        try package.addTrack("t2", clip: "c2", file: "f2", start: 0, offset: 0, length: 48_000)
        try package.session.write(to: package.url)
        return ArchiveStudioFixture(package: package)
    }

    @MainActor func open(_ hal: TestHAL = TestHAL([])) async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(hal)
        return studio
    }

    /// The names in `Clips/`, also the hidden ones (a temporary file of a conversion).
    var clipsNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.appending(path: clipsFolderName).path)) ?? [])
            .sorted()
    }

    /// The names in `Backups/`.
    var backupNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.appending(path: "Backups").path)) ?? []).sorted()
    }

    /// The bytes of `session.xml` and of each file of `Clips/`.
    func contents() throws -> [String: Data] {
        var files = ["session.xml": try Data(contentsOf: url.appending(path: "session.xml"))]
        for name in clipsNames {
            files["Clips/\(name)"] = try Data(contentsOf: url.appending(path: "\(clipsFolderName)/\(name)"))
        }
        return files
    }

    /// The session on disk.
    func stored() throws -> Session { try Session(contentsOf: url) }
}

extension Studio {
    /// A write job that no list of the gate names: it calls `checkIdle()` as each write job does.
    func jobThatTheTestAdds() throws(StudioError) { try checkIdle() }
}

/// The studio archive job and the write gate of decision 0072 (run criteria C7, C14, C16, C19,
/// C21 (e), and C23 (window part)).
@MainActor
struct StudioArchiveTests {
    let gain = Gain(dB: -6)!

    @Test func eachWriteJobRefusesAnArchivedStudio() async throws {
        let fixture = try await ArchiveStudioFixture.make()
        let studio = try await fixture.open()
        let source = fixture.package.folder.url.appending(path: "Voice.wav")
        try writeSource(source, .wav16, rate: 48_000, channels: [sine(seconds: 1, rate: 48_000)])
        _ = try await studio.archive { _ in }
        #expect(studio.isArchived)
        let (session, files) = (studio.session, try fixture.contents())
        let gain = gain

        #expect(throws: StudioError.archived, "edit") {
            try studio.edit(ripple: false) { session throws(SessionError) in try session.setGain(gain, track: "t1") }
        }
        #expect(throws: StudioError.archived, "amend") {
            try studio.amend { session throws(SessionError) in try session.setGain(gain, track: "t1") }
        }
        #expect(throws: StudioError.archived, "undo") { try studio.undo() }
        #expect(throws: StudioError.archived, "redo") { try studio.redo() }
        #expect(throws: StudioError.archived, "a job that no list names") { try studio.jobThatTheTestAdds() }
        await #expect(throws: StudioError.archived, "an import") {
            try await studio.importAudio(source, to: ImportTarget(track: nil, start: 0)) { _ in }
        }
        await #expect(throws: StudioError.archived, "a play") { try await studio.play(from: 0, to: nil) }
        await #expect(throws: StudioError.archived, "a locate") { try await studio.locate(1000) }
        await #expect(throws: StudioError.archived, "an export") {
            try await studio.export(
                ExportSource(range: 0..<48_000)!, ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .session),
                to: fixture.package.folder.url.appending(path: "mix.wav"), replacing: nil)
        }
        #expect(throws: Never.self, "the model-file check is a read") { try studio.checkModelFileIdle() }
        #expect(studio.session == session, "a refused job changed the session")
        #expect(try fixture.contents() == files, "a refused job changed a file")

        _ = try await studio.unarchive { _ in }

        #expect(!studio.isArchived)
        try studio.jobThatTheTestAdds()
        try studio.edit(ripple: false) { session throws(SessionError) in try session.setGain(gain, track: "t1") }
        #expect(studio.session.track("t1")?.gain == gain)
    }

    @Test func anArchivedPackageOpensWithNoUnarchive() async throws {
        let fixture = try await ArchiveStudioFixture.make()
        try await Self.archiveOffMain(fixture.url, clearAttribute: false)
        let files = try fixture.contents()

        let studio = try await fixture.open()
        await studio.checkMedia()

        #expect(studio.isArchived)
        #expect(studio.missingMedia == [:])
        #expect(try fixture.contents() == files, "the open changed a file")
    }

    /// U41: a FLAC that an unarchive kept as damaged has no attribute, so the edits run.
    @Test func aFLACWithNoAttributeOpensAsAWorkingPackage() async throws {
        let fixture = try await ArchiveStudioFixture.make()
        try await Self.archiveOffMain(fixture.url, clearAttribute: true)
        let studio = try await fixture.open()
        let gain = gain

        #expect(!studio.isArchived)
        try studio.edit(ripple: false) { session throws(SessionError) in try session.setGain(gain, track: "t1") }
        #expect(fixture.clipsNames == ["f1.flac", "f2.flac", "f3.flac"])
    }

    /// C19 negative control: with no other job, the archive converts each file, and the unarchive
    /// gives each WAV back. Neither save keeps a backup (U19).
    @Test func theArchiveConvertsEachFileAndTheUnarchiveGivesThemBack() async throws {
        let fixture = try await ArchiveStudioFixture.make()
        let studio = try await fixture.open()
        let backups = fixture.backupNames
        let progress = ProgressValues()

        let report = try await studio.archive { progress.list.append($0) }

        #expect(report.converted == ["f1.wav", "f2.wav", "f3.wav"])
        #expect(fixture.clipsNames == ["f1.flac", "f2.flac", "f3.flac"])
        #expect(try fixture.stored().archive == .flac)
        #expect(studio.session.archive == .flac)
        #expect(studio.transport == .idle)
        await until(limit: .seconds(10), "the last progress hop did not arrive") { progress.list.last == 1 }
        #expect(progress.list == progress.list.sorted(), "the progress goes down")

        let back = try await studio.unarchive { _ in }

        #expect(back.converted == ["f1.wav", "f2.wav", "f3.wav"])
        #expect(fixture.clipsNames == ["f1.wav", "f2.wav", "f3.wav"])
        #expect(try fixture.stored().archive == nil)
        #expect(fixture.backupNames == backups, "a package job kept a backup")
    }

    /// C16 studio part: a pending take refuses the archive, and no file changes.
    @Test func anArchiveDuringAPendingTakeIsRefused() async throws {
        let package = try TakePackage()
        FileManager.default.createFile(atPath: package.url.appending(path: "recovery-attempt").path, contents: nil)
        let studio = try await Studio.open(package.url)
        #expect(studio.pendingTake != nil)
        let before = try Data(contentsOf: package.url.appending(path: "session.xml"))

        await #expect(throws: StudioError.archive(.pendingTake)) { try await studio.archive { _ in } }
        await #expect(throws: StudioError.busy) { try await studio.unarchive { _ in } }

        #expect(try Data(contentsOf: package.url.appending(path: "session.xml")) == before)
    }

    /// C19 (a): an export of this studio and a take of another studio make the archive busy.
    @Test func anArchiveIsBusyDuringAnExportOrATakeOfAnotherStudio() async throws {
        let a = try await ExportStudioFixture.make()
        let hal = TestHAL([a.mic])
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let studioA = try await a.open(hal, seam: ChunkSeam(at: [1: { gate.waitOnce() }]))
        let export = Task { try await studioA.export(a.source, a.options, to: a.out, replacing: nil) }
        await gate.entered()

        await #expect(throws: StudioError.busy, "during an export") { try await studioA.archive { _ in } }
        gate.open()
        _ = try await export.value

        let b = try await ArchiveStudioFixture.make()
        let studioB = try await b.open()
        studioB.otherStudios = { [studioA] }
        let files = try b.contents()
        let host = try await StudioExportTests().start(.startTake, studioA, a)

        await #expect(throws: StudioError.busy, "during a take of another studio") {
            try await studioB.archive { _ in }
        }
        #expect(try b.contents() == files, "a refused archive changed a file")
        try await StudioExportTests().recordAndStop(studioA, hal, from: host)
    }

    /// C19 (d): `settle()` ends the job after the file in hand, starts no other file, and returns
    /// after the job ended. The package stays archived in part, and the next archive ends it.
    @Test func settleStopsTheArchiveAfterItsCurrentFile() async throws {
        let fixture = try await ArchiveStudioFixture.make()
        let studio = try await fixture.open()
        let backups = fixture.backupNames
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let hold = ChunkSeam(at: [1: { gate.waitOnce() }])
        studio.environment.archiveBlock = { hold.step() }
        let job = Task { try await studio.archive { _ in } }
        await gate.entered()

        let settle = Task { await studio.settle() }
        await until(limit: .seconds(10), "settle did not stop the job") { studio.archiveStop == .close }
        gate.open()
        await settle.value

        await #expect(throws: StudioError.archive(.cancelled)) { try await job.value }
        #expect(fixture.clipsNames == ["f1.flac", "f2.wav", "f3.wav"], "the job did not stop after its file")
        #expect(needsUnarchive(try fixture.stored()), "the package lost its attribute")
        #expect(studio.isArchived)
        #expect(fixture.backupNames == backups, "the close kept a backup of the archived session")

        _ = try await studio.archive { _ in }

        #expect(fixture.clipsNames == ["f1.flac", "f2.flac", "f3.flac"])
    }

    /// U10: Cancel stops after the file in hand, and the next unarchive ends the job.
    @Test func aCancelStopsTheArchiveAfterItsCurrentFile() async throws {
        let fixture = try await ArchiveStudioFixture.make()
        let studio = try await fixture.open()
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let hold = ChunkSeam(at: [1: { gate.waitOnce() }])
        studio.environment.archiveBlock = { hold.step() }
        let job = Task { try await studio.archive { _ in } }
        await gate.entered()

        studio.cancelArchive()
        gate.open()

        await #expect(throws: StudioError.archive(.cancelled)) { try await job.value }
        #expect(studio.archiveStop == .user)
        #expect(fixture.clipsNames == ["f1.flac", "f2.wav", "f3.wav"])
        #expect(studio.isArchived)

        _ = try await studio.unarchive { _ in }

        #expect(fixture.clipsNames == ["f1.wav", "f2.wav", "f3.wav"])
        #expect(!studio.isArchived)
        #expect(try fixture.stored().archive == nil)
    }

    /// C19 (b): a take start in another studio ends the job at its next block check: the file in
    /// hand keeps its WAV, no temporary file stays, and the take starts.
    @Test func aTakeInAnotherStudioStopsTheArchiveAtItsNextBlock() async throws {
        let a = try await ExportStudioFixture.make()
        let hal = TestHAL([a.mic])
        let studioA = try await a.open(hal)
        let b = try await ArchiveStudioFixture.make()
        let studioB = try await b.open()
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let hold = ChunkSeam(at: [1: { gate.waitOnce() }])
        studioB.environment.archiveBlock = { hold.step() }
        let job = Task { try await studioB.archive { _ in } }
        await gate.entered()
        studioA.otherStudios = { [studioB] }

        let start = Task { try await studioA.startTake(armed: ["t1"], devices: [a.mic], hostTimeNanos: takeStart) }
        await until(limit: .seconds(10), "the take start waits for the archive thread") {
            studioA.transport == .recording(take: 1)
        }
        gate.open()

        await #expect(throws: StudioError.archive(.cancelled)) { try await job.value }
        #expect(studioB.archiveStop == .take)
        #expect(b.clipsNames == ["f1.wav", "f2.wav", "f3.wav"], "the file in hand changed its form")
        #expect(needsUnarchive(try b.stored()), "the package lost its attribute")
        _ = try await start.value
        try await StudioExportTests().recordAndStop(studioA, hal, from: takeStart)
    }

    /// C21 (e): the close of an archived window keeps no backup; after the unarchive it keeps one,
    /// with no attribute.
    @Test func theCloseOfAnArchivedWindowKeepsNoBackup() async throws {
        let fixture = try await ArchiveStudioFixture.make()
        let studio = try await fixture.open()
        let backups = fixture.backupNames
        _ = try await studio.archive { _ in }

        await studio.settle()

        #expect(fixture.backupNames == backups, "the close kept a backup of the archived session")

        _ = try await studio.unarchive { _ in }
        await studio.settle()

        let names = fixture.backupNames
        #expect(names.count == backups.count + 1, "the close of the working session kept no backup")
        for name in names {
            let text = try String(contentsOf: fixture.url.appending(path: "Backups/\(name)"), encoding: .utf8)
            #expect(!text.contains("archive="), "a backup holds the archive state")
        }
    }

    /// C23 window part: Save as Template copies out of an archived window with no unarchive.
    @Test func saveAsTemplateRunsOnAnArchivedStudio() async throws {
        let fixture = try await ArchiveStudioFixture.make()
        let studio = try await fixture.open()
        _ = try await studio.archive { _ in }
        let files = try fixture.contents()
        let target = fixture.package.folder.url.appending(path: "Show.dirigible")

        try await studio.saveTemplate(to: target)

        #expect(studio.isArchived)
        #expect(try fixture.contents() == files, "the copy changed a file of the window")
        let copied = try FileManager.default.contentsOfDirectory(atPath: target.appending(path: clipsFolderName).path)
        #expect(copied.allSatisfy { $0.hasSuffix(".wav") } && !copied.isEmpty, "the template holds a FLAC")
    }

    /// Archives the package with the library job off the main actor; with `clearAttribute`, saves
    /// the session again with no attribute (the state after an unarchive that kept a FLAC).
    @concurrent nonisolated static func archiveOffMain(_ url: URL, clearAttribute: Bool) async throws {
        var session = try Session(contentsOf: url)
        _ = try archivePackage(
            &session, in: url,
            save: { saved throws(SessionFileError) in
                try saved.write(to: url)
                return url
            })
        if clearAttribute {
            session.archive = nil
            try session.write(to: url)
        }
    }
}
