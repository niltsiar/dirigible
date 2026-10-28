import Foundation
import IOKit.pwr_mgt
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// `Studio.renderClips` (decision 0054): one undo entry that keeps the WAVs, the blocking run
/// rules, the activity, the cancel and save faults, the render thread, and the capture after a
/// prune.
@MainActor
struct StudioRenderTests {
    let noise = ClipRenderRequest(Treatment(.noise(.standard)))

    /// A studio on `package` with the test environment, and a reason text of its own.
    func open(_ package: MixPackage, hal: TestHAL = TestHAL([])) async throws -> Studio {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(hal)
        studio.environment.blockingRunReason = UUID().uuidString
        return studio
    }

    func xml(_ package: MixPackage) -> Data? {
        FileManager.default.contents(atPath: package.url.appending(path: "session.xml").path)
    }

    /// The names in `Clips/` of `package`, temp files too.
    func listing(_ package: MixPackage) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: clipsFolderName).path).sorted()
    }

    /// Runs one render of `clips` and gives its error, or nil.
    func run(_ studio: Studio, _ clips: [ClipID] = ["c1"]) -> Task<StudioError?, Never> {
        let noise = noise
        return Task {
            do throws(StudioError) {
                _ = try await studio.renderClips(clips, request: noise) { _ in }
                return nil
            } catch {
                return error
            }
        }
    }

    /// The IOPM assertions of this process named `reason`.
    func assertions(_ reason: String) throws -> Int {
        var byProcess: Unmanaged<CFDictionary>?
        try #require(IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess)
        let processes = try #require(byProcess?.takeRetainedValue() as? [NSNumber: [NSDictionary]])
        return (processes[NSNumber(value: getpid())] ?? []).count(where: { $0["AssertName"] as? String == reason })
    }

    /// C8: one undo entry that names the agent. Undo restores the source file of the clip, the WAVs
    /// stay, and Redo writes nothing.
    @Test func undoRestoresTheSource() async throws {
        let fixture = try await StudioSplitTests.make()
        let studio = try await open(fixture.package)
        let before = studio.session
        let agent = AgentName(title: "Test Agent", clientName: nil)

        let report = try await studio.renderClips(["c1"], request: noise, agent: agent) { _ in }

        let saved = try Session(contentsOf: fixture.package.url)
        let moved = try #require(studio.session.clip("c1")?.clip)
        #expect(saved == studio.session && report.clips == [RenderedClip(clip: "c1", file: moved.file)])
        #expect(report.noise == .standard && studio.session.files[moved.file]?.path == "f1 NR.wav")
        #expect(studio.undoAgent == agent, "the undo entry names the agent")
        let files = ["f1 NR.wav", "f1.wav"]
        #expect(try listing(fixture.package) == files)
        try studio.undo()
        #expect(studio.session == before && !studio.canUndo, "Undo restores the source file")
        #expect(try listing(fixture.package) == files, "the WAVs stay after Undo")
        try studio.redo()
        let afterRedo = try listing(fixture.package)
        #expect(studio.session == saved && afterRedo == files, "Redo writes nothing")
        await studio.settle()
    }

    /// C5: during a play, the amount of the level again gives the clip as unchanged, with no save
    /// and no undo level. It is a blocking run, so the play stops. Undo still goes back to before
    /// the first render.
    @Test func equalAmountRecordsNothing() async throws {
        let fixture = try await StudioSplitTests.make()
        let studio = try await open(fixture.package)
        let source = studio.session
        let first = try await studio.renderClips(["c1"], request: noise) { _ in }
        try #require(first.clips.count == 1, "the first render moves the clip")
        _ = try await studio.play(from: 0, to: nil)
        try #require(studio.playback != .stopped)
        let before = (studio.session, xml(fixture.package), try listing(fixture.package))

        let report = try await studio.renderClips(["c1"], request: noise) { _ in }

        #expect(report.unchanged == ["c1"] && report.clips.isEmpty)
        #expect(studio.playback == .stopped, "the blocking run stops the play")
        #expect(studio.session == before.0 && xml(fixture.package) == before.1)
        #expect(try listing(fixture.package) == before.2)
        try studio.undo()
        #expect(studio.session == source && !studio.canUndo, "one undo level, of the first render")
        await studio.settle()
    }

    /// C3: a change of the amount on a rendered clip is one undo entry: Undo puts back the file of
    /// the old amount, and a second Undo puts back the source.
    @Test func changeIsOneUndoEntry() async throws {
        let fixture = try await StudioSplitTests.make()
        let studio = try await open(fixture.package)
        let source = studio.session
        let first = try await studio.renderClips(["c1"], request: noise) { _ in }
        try #require(first.clips.count == 1, "the first render moves the clip")
        let rendered = studio.session
        let twenty = ClipRenderRequest(Treatment(.noise(NoiseReduction(decibels: 20)!)))

        let report = try await studio.renderClips(["c1"], request: twenty) { _ in }

        try #require(report.clips.count == 1 && report.unchanged.isEmpty, "the change moves the clip")
        try studio.undo()
        #expect(studio.session == rendered, "one Undo puts back the file of 12 dB")
        #expect(try listing(fixture.package).contains("f1 NR.wav"), "the file of 12 dB stays")
        try studio.undo()
        #expect(studio.session == source && !studio.canUndo, "the change records one undo entry")
        await studio.settle()
    }

    /// C5: a blocking run whose work gives the session of its turn back saves nothing and records
    /// no undo level.
    @Test func unchangedTurnWritesNothing() async throws {
        let fixture = try await StudioSplitTests.make()
        let studio = try await open(fixture.package)
        let (saves, ran) = (LockedBox<Int>(), LockedBox<Bool>())
        let save = studio.environment.saveSession
        studio.environment.saveSession = { session, lock throws(SessionFileError) in
            saves.value = (saves.value ?? 0) + 1
            return try await save(session, lock)
        }
        func turn(_ edit: @escaping @Sendable (Session) -> Session) async throws(StudioError) -> Int {
            try await studio.blockingRun(
                name: "f1", kind: .clipRender, cancelled: .clipRender(.cancelled), yielded: .clipRenderYielded,
                ripple: false
            ) { session, _, _ in
                ran.value = true
                return .success((edit(session), 7, made: []))
            }
        }

        #expect(try await turn { $0 } == 7 && ran.value == true)

        #expect(saves.value == nil && !studio.canUndo, "\(String(describing: saves.value)) saves")
        _ = try await turn { session in
            var changed = session
            try? changed.setGain(Gain(dB: 3)!, clip: "c1")
            return changed
        }
        #expect(saves.value == 1 && studio.canUndo, "control: a changed session saves")
        await studio.settle()
    }

    /// A blocking run whose work gives the session of its turn back removes the files that the
    /// work made.
    @Test func unchangedTurnRemovesItsFiles() async throws {
        let fixture = try await StudioSplitTests.make()
        let studio = try await open(fixture.package)
        let before = try listing(fixture.package)
        let made = fixture.package.url.appending(path: clipsFolderName).appending(path: "f1 NR.wav")
        let created = LockedBox<Bool>()

        let value = try await studio.blockingRun(
            name: "f1", kind: .clipRender, cancelled: .clipRender(.cancelled), yielded: .clipRenderYielded,
            ripple: false
        ) { session, _, _ in
            created.value = FileManager.default.createFile(atPath: made.path, contents: Data([0]))
            return .success((session, 7, made: [made]))
        }

        try #require(value == 7 && created.value == true, "the work made no file")
        let after = try listing(fixture.package)
        #expect(after == before && !studio.canUndo, "the turn left \(after)")
        await studio.settle()
    }

    /// C9: a render during a take is busy and writes nothing, also when the clip is `unchanged`
    /// (item 1131); the take goes on.
    @Test(arguments: [false, true]) func busyDuringTake(unchanged: Bool) async throws {
        let fixture = try await ExportStudioFixture.make()
        let hal = TestHAL([fixture.mic])
        let studio = try await fixture.open(hal)
        if unchanged {
            let first = try await studio.renderClips(["c1"], request: noise) { _ in }
            try #require(first.clips.count == 1, "the first render moves the clip")
        }
        let clips = fixture.package.url.appending(path: clipsFolderName)
        let before = try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted()
        _ = try await studio.startTake(armed: ["t1"], devices: [fixture.mic], hostTimeNanos: takeStart)

        await #expect(throws: StudioError.busy) { try await studio.renderClips(["c1"], request: noise) { _ in } }

        #expect(try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted() == before)
        #expect(studio.transport == .recording(take: 1), "the take goes on")
        try await StudioExportTests().recordAndStop(studio, hal, from: takeStart)
    }

    /// C9: a take in another studio yields a render that waits before its save: the render throws
    /// `.clipRenderYielded`, its WAV goes, and its session does not change.
    @Test func takeYieldsTheRender() async throws {
        let a = try await ExportStudioFixture.make()
        let hal = TestHAL([a.mic])
        let studioA = try await a.open(hal)
        let b = try await StudioSplitTests.make()
        let studioB = try await open(b.package)
        let gate = AsyncGate()
        studioB.environment.clipRenderWorkDone = { await gate.wait() }
        let before = (studioB.session, xml(b.package))
        let render = run(studioB)
        await gate.entered()
        #expect(try listing(b.package) == ["f1 NR.wav", "f1.wav"], "the render made its WAV")
        studioA.otherStudios = { [studioB] }

        let host = try await StudioExportTests().start(.startTake, studioA, a)
        gate.open()

        #expect(await render.value == .clipRenderYielded)
        #expect(studioB.session == before.0 && xml(b.package) == before.1 && !studioB.canUndo)
        #expect(try listing(b.package) == ["f1.wav"], "the yield removed the WAV")
        try await StudioExportTests().recordAndStop(studioA, hal, from: host)
        await studioB.settle()
    }

    /// C9b: each blocking run holds one activity from its start to its end: a render that the
    /// banner cancels, an import that saves; a run that `.busy` refuses holds none.
    @Test func blockingRunHoldsTheActivity() async throws {
        let fixture = try await StudioSplitTests.make()
        let studio = try await open(fixture.package)
        let reason = studio.environment.blockingRunReason
        let gate = AsyncGate()
        studio.environment.clipRenderWorkDone = { await gate.wait() }
        #expect(try assertions(reason) == 0, "control: none before the run")

        let render = run(studio)
        await gate.entered()
        #expect(try assertions(reason) == 1, "the render holds the activity")
        #expect(await run(studio).value == .busy)
        #expect(try assertions(reason) == 1, "the refused run holds none")
        studio.cancelImport()
        gate.open()
        #expect(await render.value == .clipRender(.cancelled))
        #expect(try assertions(reason) == 0, "the cancelled render ended its activity")

        let source = try await ImportStudioFixture.make()
        let importing = try await source.open()
        let importReason = UUID().uuidString
        importing.environment.blockingRunReason = importReason
        let importGate = AsyncGate()
        importing.environment.importWorkDone = { await importGate.wait() }
        let target = ImportTarget(track: nil, start: 0)
        let task = Task { try await importing.importAudio(source.source, to: target) { _ in } }
        await importGate.entered()
        #expect(try assertions(importReason) == 1, "the import holds the activity")
        importGate.open()
        _ = try await task.value
        #expect(try assertions(importReason) == 0, "the saved import ended its activity")
        await studio.settle()
        await importing.settle()
    }

    /// C7: a failed save keeps the renamed WAV as an unused file and changes no session.
    @Test func saveFaultKeepsFiles() async throws {
        let fixture = try await StudioSplitTests.make()
        let studio = try await open(fixture.package)
        let before = (studio.session, xml(fixture.package))
        studio.environment.saveSession = { _, _ throws(SessionFileError) in
            throw .writeFailed(step: "test", errno: EIO)
        }

        #expect(await run(studio).value == .file(.writeFailed(step: "test", errno: EIO)))

        #expect(studio.session == before.0 && xml(fixture.package) == before.1 && !studio.canUndo)
        #expect(try listing(fixture.package) == ["f1 NR.wav", "f1.wav"], "the WAV stays as an unused file")
        #expect(studio.transport == .idle)
        await studio.settle()
    }

    /// C7: a cancel after the render returns, before the save, removes the renamed WAV.
    @Test func lateCancelRemovesFiles() async throws {
        let fixture = try await StudioSplitTests.make()
        let studio = try await open(fixture.package)
        let gate = AsyncGate()
        studio.environment.clipRenderWorkDone = { await gate.wait() }
        let before = (studio.session, xml(fixture.package))

        let render = run(studio)
        await gate.entered()
        #expect(try listing(fixture.package) == ["f1 NR.wav", "f1.wav"], "the render made its WAV")
        studio.cancelImport()
        gate.open()

        #expect(await render.value == .clipRender(.cancelled))
        #expect(try listing(fixture.package) == ["f1.wav"], "the cancel left the WAV")
        #expect(studio.session == before.0 && xml(fixture.package) == before.1 && !studio.canUndo)
        await studio.settle()
    }

    /// C19b: the render reads its source off the main thread.
    @Test func renderRunsOffTheMainThread() async throws {
        let fixture = try await StudioSplitTests.make()
        let studio = try await open(fixture.package)
        let onMain = LockedBox<Bool>()
        studio.environment.clipRenderRead = ReadFault(stem: "f1 NR", block: 0) { onMain.value = Thread.isMainThread }

        _ = try await studio.renderClips(["c1"], request: noise) { _ in }

        #expect(onMain.value == false)
        await studio.settle()
    }

    /// C1: the new file keeps the capture of the take, so the take is not offered for Place. The
    /// source WAV is the origin of the new file, so a prune keeps it (decision 0057).
    @Test func pruneAfterRenderKeepsTakePlaced() async throws {
        let segment = SegmentName(take: 1, arm: 1, segment: 1)
        let package = try await StudioSplitTests.takePackage(segment)
        var first: Studio? = try await open(package)
        _ = try await first?.renderClips(["c1"], request: noise) { _ in }
        await first?.settle()
        first = nil  // The close: the next open takes the lock.
        // The backup of the save before the render names f1: without it, only the origin keeps f1.
        try FileManager.default.removeItem(at: package.url.appending(path: backupsFolderName))
        let studio = try await open(package)
        #expect(unplacedSegments([segment], session: Session(sampleRate: 48_000)) == [segment], "control")

        let scan = try await studio.unusedFiles()

        #expect(scan.items.isEmpty, "the source of the rendered file is in use")
        #expect(studio.session.files["f1"] != nil && studio.session.files["f1 NR"]?.origin?.source == "f1")
        #expect(studio.unplacedSegments == [], "the take is not offered for Place")
        await studio.settle()
    }
}
