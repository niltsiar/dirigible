import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Save as Template runs in the export job slot of the studio (T7).
@MainActor
struct StudioTemplateTests {
    /// The names in the folder of the package: the package, and the template when it exists.
    func names(_ fixture: ExportStudioFixture) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixture.package.folder.url.path).sorted()
    }

    /// A chunk seam that holds the first cancel read of a copy (the staging folder exists then)
    /// until `gate` opens. Open it after the stop sets `exportStop`: a stop under load is slow.
    func heldSeam(_ gate: Gate) -> ChunkSeam { ChunkSeam(at: [1: { gate.waitOnce() }]) }

    /// T7: a take start in this window ends the copy, which throws `.template(.cancelled)` and
    /// leaves no package, no staging folder, and no lock file.
    @Test func aTakeStartEndsSaveTemplate() async throws {
        let fixture = try await ExportStudioFixture.make()
        let hal = TestHAL([fixture.mic])
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let studio = try await fixture.open(hal, seam: heldSeam(gate))
        let target = fixture.package.folder.url.appending(path: "Show.dirigible")
        let save = Task { try await studio.saveTemplate(to: target) }
        await gate.entered()

        let start = Task {
            _ = try await studio.startTake(armed: ["t1"], devices: [fixture.mic], hostTimeNanos: takeStart)
        }
        await until(limit: .seconds(30), "the take start did not end the copy") { studio.exportStop == .take }
        gate.open()

        await #expect(throws: StudioError.template(.cancelled)) { try await save.value }
        try await start.value
        #expect(studio.exportStop == .take)
        #expect(try names(fixture) == ["Mix.dirigible"], "no template, staging folder, or lock file")
        let input = SyntheticInput(hal, "mic")
        input.play(records([sine(seconds: 0.25, rate: 48_000)], layout: [1], rate: 48_000, hostStart: takeStart))
        await input.wait()
        try await studio.stopRecording()
    }

    /// T7: `settle()` (the close of the window) ends the copy and leaves nothing.
    @Test func settleEndsSaveTemplate() async throws {
        let fixture = try await ExportStudioFixture.make()
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let studio = try await fixture.open(seam: heldSeam(gate))
        let target = fixture.package.folder.url.appending(path: "Show.dirigible")
        let save = Task { try await studio.saveTemplate(to: target) }
        await gate.entered()

        let settle = Task { await studio.settle() }
        await until(limit: .seconds(30), "settle did not end the copy") { studio.exportStop == .close }
        gate.open()

        await #expect(throws: StudioError.template(.cancelled)) { try await save.value }
        await settle.value
        #expect(studio.exportStop == .close)
        #expect(try names(fixture) == ["Mix.dirigible"], "no template, staging folder, or lock file")
    }

    /// The studio says when the job in its export slot is a Save as Template: the window reads it for the title of
    /// the progress sheet. An export is no template save.
    @Test func theStudioSaysWhenItSavesATemplate() async throws {
        let fixture = try await ExportStudioFixture.make()
        let seam = ChunkSeam(pause: longChunk)
        let studio = try await fixture.open(seam: seam)
        let target = fixture.package.folder.url.appending(path: "Show.dirigible")
        #expect(!studio.savesTemplate, "no job")
        let save = Task { try await studio.saveTemplate(to: target) }
        await until(limit: .seconds(30), "the copy did not read its cancel flag") { seam.calls > 0 }
        #expect(studio.savesTemplate, "the copy runs")
        await studio.settle()
        await #expect(throws: StudioError.template(.cancelled)) { try await save.value }
        #expect(!studio.savesTemplate, "the copy ended")

        let calls = seam.calls
        let (source, options, out) = (fixture.source, fixture.options, fixture.out)
        let export = Task { try await studio.export(source, options, to: out, replacing: nil) }
        await until(limit: .seconds(30), "the export did not start") { seam.calls > calls }
        #expect(studio.exportProgress != nil && !studio.savesTemplate, "an export is no template save")
        studio.cancelExport()
        await #expect(throws: StudioError.export(.cancelled)) { try await export.value }
    }

    /// T7: during an export, Save as Template throws `.busy` and makes nothing; the export goes on.
    @Test func saveTemplateDuringAnExportIsBusy() async throws {
        let fixture = try await ExportStudioFixture.make()
        let seam = ChunkSeam(pause: longChunk)
        let studio = try await fixture.open(seam: seam)
        let (source, options, out) = (fixture.source, fixture.options, fixture.out)
        let export = Task { try await studio.export(source, options, to: out, replacing: nil) }
        await until(limit: .seconds(30), "the export did not start") { seam.calls > 0 }
        let target = fixture.package.folder.url.appending(path: "Show.dirigible")

        await #expect(throws: StudioError.busy) { try await studio.saveTemplate(to: target) }

        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(studio.exportProgress != nil, "the export still runs")
        studio.cancelExport()
        await #expect(throws: StudioError.export(.cancelled)) { try await export.value }
    }

    /// T7: a take start ends the copy inside one file. The file is 34.56 MB and does not clone,
    /// so the copy makes one write for each MiB. The write seam holds write 3 until the take start
    /// has set the cancel flag; after it the copy makes at most one more write.
    @Test func aTakeStartEndsSaveTemplateInsideOneFile() async throws {
        let fixture = try await ExportStudioFixture.make { package in
            try package.addFile("long", channels: [[Float](repeating: 0.25, count: 48_000 * 240)])
            try package.session.place(
                Clip(id: "c2", file: "long", start: 480_000, offset: 0, length: 48_000), on: "t1")
        }
        let hal = TestHAL([fixture.mic])
        let studio = try await fixture.open(hal)
        let writes = LockedBox<Int>()
        let released = LockedBox<Bool>()
        studio.environment.templateCanClone = { _, _ in false }
        studio.environment.templateWritten = { path, _ in
            guard path.hasSuffix("long.wav") else { return }
            let count = (writes.value ?? 0) + 1
            writes.value = count
            guard count == 3 else { return }
            let watch = Stopwatch()
            while released.value != true, watch.wall < .seconds(30) { Thread.sleep(forTimeInterval: 0.01) }
        }
        let target = fixture.package.folder.url.appending(path: "Show.dirigible")
        let save = Task { try await studio.saveTemplate(to: target) }
        await until(limit: .seconds(30), "the copy did not reach write 3") { writes.value == 3 }

        let start = Task {
            _ = try await studio.startTake(armed: ["t1"], devices: [fixture.mic], hostTimeNanos: takeStart)
        }
        // `endExport` sets `exportStop` and cancels the job in one main-actor turn.
        await until(limit: .seconds(30), "the take start did not end the copy") { studio.exportStop == .take }
        released.value = true

        await #expect(throws: StudioError.template(.cancelled)) { try await save.value }
        try await start.value
        #expect((writes.value ?? 0) <= 4, "at most one write after the cancel flag, of 33")
        #expect(try names(fixture) == ["Mix.dirigible"], "no template, staging folder, or lock file")
        let input = SyntheticInput(hal, "mic")
        input.play(records([sine(seconds: 0.25, rate: 48_000)], layout: [1], rate: 48_000, hostStart: takeStart))
        await input.wait()
        try await studio.stopRecording()
    }

    /// T7: a take start in another window ends the copy of this window.
    @Test func aTakeInAnotherWindowEndsSaveTemplate() async throws {
        let a = try await ExportStudioFixture.make()
        let hal = TestHAL([a.mic])
        let studioA = try await a.open(hal)
        let b = try await ExportStudioFixture.make()
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let studioB = try await b.open(seam: heldSeam(gate))
        let target = b.package.folder.url.appending(path: "Show.dirigible")
        let save = Task { try await studioB.saveTemplate(to: target) }
        await gate.entered()
        studioA.otherStudios = { [studioB] }

        let start = Task { try await StudioExportTests().start(.startTake, studioA, a) }
        await until(limit: .seconds(30), "the take start did not end the copy") { studioB.exportStop == .take }
        gate.open()

        await #expect(throws: StudioError.templateYielded) { try await save.value }
        let host = try await start.value
        #expect(studioB.exportStop == .take)
        #expect(try names(b) == ["Mix.dirigible"], "no template, staging folder, or lock file")
        try await StudioExportTests().recordAndStop(studioA, hal, from: host)
    }

    /// T7: the disk check of a take in another window ends a copy to its volume, and the take
    /// runs on. The free space is 0 while the folder of the copy has more than the package.
    @Test func aTakeDiskCheckEndsSaveTemplateOnItsVolume() async throws {
        let a = try await ExportStudioFixture.make()
        let studioA = try await a.open()
        let folderB = LockedBox<URL>()
        studioA.environment.freeBytes = { _ in
            let names = folderB.value.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }
            return (names?.count ?? 0) > 1 ? 0 : 100_000_000_000
        }
        try await studioA.startRecording(armed: ["t1"])
        let b = try await ExportStudioFixture.make()
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let studioB = try await b.open(seam: heldSeam(gate))
        let target = b.package.folder.url.appending(path: "Show.dirigible")
        let save = Task { try await studioB.saveTemplate(to: target) }
        await gate.entered()
        studioA.otherStudios = { [studioB] }
        folderB.value = b.package.folder.url
        await until(limit: .seconds(30), "the disk check did not end the copy") { studioB.exportStop == .take }
        gate.open()

        await #expect(throws: StudioError.templateYielded) { try await save.value }
        #expect(studioB.exportStop == .take)
        #expect(try names(b) == ["Mix.dirigible"], "no template, staging folder, or lock file")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(studioA.transport == .recording(take: 1))
        try await studioA.stopRecording()
    }

    /// T7: the template has an edit of one call before, which is not on disk (the save fails).
    @Test func saveTemplateHasTheLastEdit() async throws {
        let fixture = try await ExportStudioFixture.make()
        let studio = try await fixture.open()
        studio.environment.saveSession = { _, _ throws(SessionFileError) in
            throw .writeFailed(step: "test", errno: EIO)
        }
        try studio.edit(ripple: false) { session throws(SessionError) in try session.renameTrack("t1", to: "Host") }
        let target = fixture.package.folder.url.appending(path: "Show.dirigible")

        try await studio.saveTemplate(to: target)

        #expect(try Session(contentsOf: target).track("t1")?.name == "Host")
        #expect(try Session(contentsOf: fixture.package.url).track("t1")?.name != "Host", "the disk has no edit")
    }

    /// T7: a finalize that fails (no `Capture/`) leaves the take pending; then the save is busy.
    @Test func saveTemplateWithAPendingTakeIsBusy() async throws {
        let fixture = try await ExportStudioFixture.make()
        let hal = TestHAL([fixture.mic])
        let studio = try await fixture.open(hal)
        let capture = fixture.package.url.appending(path: "Capture")
        studio.environment.beforeFinalize = { try? FileManager.default.removeItem(at: capture) }
        _ = try await studio.startTake(armed: ["t1"], devices: [fixture.mic], hostTimeNanos: takeStart)
        let input = SyntheticInput(hal, "mic")
        input.play(records([sine(seconds: 0.25, rate: 48_000)], layout: [1], rate: 48_000, hostStart: takeStart))
        await input.wait()
        try? await studio.stopRecording()
        try #require(studio.pendingTake != nil)
        let target = fixture.package.folder.url.appending(path: "Show.dirigible")

        await #expect(throws: StudioError.busy) { try await studio.saveTemplate(to: target) }

        #expect(try names(fixture) == ["Mix.dirigible"])
    }

    /// T7: while the job slot holds a template copy, Remove Unused Files is busy and moves no
    /// file; after the copy it moves the file.
    @Test func removeUnusedFilesDuringSaveTemplateIsBusy() async throws {
        let fixture = try await ExportStudioFixture.make { package in
            try package.addFile("u", channels: [[Float](repeating: 0.25, count: 48_000)])
        }
        let seam = ChunkSeam(pause: longChunk)
        let studio = try await fixture.open(seam: seam)
        let scan = try await studio.unusedFiles()
        let unused = await studio.clipURLs(["u"])
        try #require(unused.count == 1)
        let target = fixture.package.folder.url.appending(path: "Show.dirigible")
        let save = Task { try await studio.saveTemplate(to: target) }
        await until(limit: .seconds(30), "the copy did not read its cancel flag") { seam.calls > 0 }

        await #expect(throws: StudioError.busy) { _ = try await studio.removeUnusedFiles(scan) }

        #expect(FileManager.default.fileExists(atPath: unused[0].path))
        try await save.value
        _ = try await studio.removeUnusedFiles(scan)
        #expect(!FileManager.default.fileExists(atPath: unused[0].path))
    }
}

/// `Studio.create` with a template (T6, T7, T13): the copy runs before a studio exists.
@MainActor
struct StudioTemplateCreateTests {
    /// A copy job list whose copy holds before its first file until `gate` opens. Open it after
    /// the stop ends the job (`yielded`): a stop under load is slow.
    func heldJobs(_ gate: Gate) -> CopyJobs {
        let jobs = CopyJobs()
        jobs.environment.templateBeforeCopy = { _ in gate.waitOnce() }
        return jobs
    }

    /// T7: a take start in a window ends the template create through `exportEnd`.
    @Test func aTakeStartEndsATemplateCreate() async throws {
        let fixture = try await ExportStudioFixture.make()
        let hal = TestHAL([fixture.mic])
        let studio = try await fixture.open(hal)
        let template = try TemplateFixture()
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let jobs = heldJobs(gate)
        studio.copyJobs = jobs
        let (target, source) = (template.target, template.template)
        let create = Task { try await Studio.create(target, source: .template(source), copyJobs: jobs) }
        await gate.entered()

        let start = Task { try await StudioExportTests().start(.startTake, studio, fixture) }
        await until(limit: .seconds(30), "the take start did not end the copy") { jobs.jobs.first?.yielded == true }
        gate.open()

        await #expect(throws: StudioError.templateYielded) { _ = try await create.value }
        let host = try await start.value
        #expect(template.parentNames == ["Show.dirigible"], "no package, staging folder, or lock file")
        #expect(jobs.jobs.isEmpty)
        try await StudioExportTests().recordAndStop(studio, hal, from: host)
    }

    /// T7: the disk check of a take ends a template create into a folder on its volume, and the
    /// take runs on. The free space is 0 while the folder of the copy has more than the template.
    @Test func aTakeDiskCheckEndsATemplateCreateOnItsVolume() async throws {
        let fixture = try await ExportStudioFixture.make()
        let studio = try await fixture.open()
        let template = try TemplateFixture()
        let folder = template.folder.url
        studio.environment.freeBytes = { _ in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.count > 1 ? 0 : 100_000_000_000
        }
        try await studio.startRecording(armed: ["t1"])
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let jobs = heldJobs(gate)
        studio.copyJobs = jobs
        let (target, source) = (template.target, template.template)
        let create = Task { try await Studio.create(target, source: .template(source), copyJobs: jobs) }
        await until(limit: .seconds(30), "the disk check did not end the copy") { jobs.jobs.first?.yielded == true }
        gate.open()

        await #expect(throws: StudioError.templateYielded) { _ = try await create.value }
        #expect(template.parentNames == ["Show.dirigible"], "no package, staging folder, or lock file")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(studio.transport == .recording(take: 1))
        try await studio.stopRecording()
    }

    /// A template at 44100 Hz with one clip, a transcript, and a capture that no file names.
    func template() throws -> MixPackage {
        let package = try MixPackage(sampleRate: 44_100)
        try package.addFile("f1", channels: [[Float](repeating: 0.25, count: 44_100)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 44_100)
        let json = #"{"words":[{"word":"hello","start":0.5,"end":0.9}]}"#
        try package.session.importTranscript(
            try TranscriptFile(data: Data(json.utf8)), name: "t.json", track: "t1", at: 0)
        try package.session.write(to: package.url)
        let capture = package.url.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        try Data(count: 100).write(to: capture.appending(path: "take1.caf"))
        return package
    }

    /// The files under `url`, as relative paths.
    func files(under url: URL) -> [String] {
        (FileManager.default.subpaths(atPath: url.path) ?? []).filter { path in
            var folder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.appending(path: path).path, isDirectory: &folder)
            return !folder.boolValue
        }
    }

    /// T6: the new session has the rate of the template, not 48000 Hz.
    @Test func aSessionFromATemplateHasTheTemplateRate() async throws {
        let package = try template()
        let target = package.folder.url.appending(path: "New.dirigible")

        let studio = try await Studio.create(target, source: .template(package.url))

        #expect(studio.session.sampleRate == 44_100)
        #expect(try Session(contentsOf: target).sampleRate == 44_100)
    }

    /// T13: `Studio.create` applies the template rule: no transcript and no capture copy.
    @Test func studioCreateDropsTheTranscript() async throws {
        let package = try template()
        try #require(files(under: package.url).contains { $0.hasPrefix("Transcripts/") })
        let target = package.folder.url.appending(path: "New.dirigible")

        let studio = try await Studio.create(target, source: .template(package.url))

        #expect(!files(under: target).contains { $0.hasPrefix("Transcripts/") })
        #expect(!FileManager.default.fileExists(atPath: target.appending(path: "Capture/take1.caf").path))
        #expect(studio.session == (try Session(contentsOf: package.url).newEpisode().session))
    }

    /// A session package that went away under the save is a failure of the source, not a read failure of a template.
    @Test func aMissingSessionPackageIsASourceFailure() async throws {
        let fixture = try await ExportStudioFixture.make()
        let studio = try await fixture.open()
        let target = fixture.package.folder.url.appending(path: "Show.dirigible")
        try FileManager.default.removeItem(at: fixture.package.url)

        await #expect(throws: StudioError.template(.source(.packageMoved))) {
            try await studio.saveTemplate(to: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path), "no template")
    }
}
