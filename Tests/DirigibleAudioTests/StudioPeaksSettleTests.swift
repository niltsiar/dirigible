import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The peak pass during a take and a close (timeline-view criteria 4, 5, 20, 21, and 22). A take
/// uses the test seam `startTake` with records from `takeStart`. The tests run one at a time.
@Suite(.serialized)
struct StudioPeaksSettleTests {
    /// Starts take 1 on `t1` and sends 1 s of records through the ring of `mic`.
    @MainActor
    func record(_ studio: Studio) async throws {
        let hal = TestHAL([PeakPackage.mic])
        studio.environment.hal = hal.hal
        _ = try await studio.startTake(armed: ["t1"], devices: [PeakPackage.mic], playhead: 0, hostTimeNanos: takeStart)
        let input = SyntheticInput(hal, "mic")
        input.play(
            records([sine(seconds: 1, rate: 48_000)], layout: [1], rate: 48_000, hostStart: takeStart + 1_000_000))
        await input.wait()
    }

    /// The new files of take 1 in the pool of `studio`.
    @MainActor
    func takeFiles(_ studio: Studio) -> [FileID] {
        studio.session.files.keys.filter { $0 != "f1" }.sorted()
    }

    /// A take starts while the pass is held inside the hook of block 1. No hook call starts
    /// from the take start to the end of its finalize; then the compute ends `.ready`.
    @Test @MainActor func aTakeNeverWaitsAndNoBlockStartsDuringIt() async throws {
        let fixture = try await PeakPackage.make()
        let (gate, blocks) = (AsyncGate(), StepCounter())
        let studio = try await fixture.studio {
            _ = blocks.next()
            await gate.wait()
        }
        await gate.entered()
        let before = blocks.calls

        try await record(studio)
        gate.open()
        try await Task.sleep(for: .milliseconds(300))
        try await studio.stopRecording()

        #expect(blocks.calls == before, "a block started during the take")
        #expect(studio.lastTake?.droppedFrames == [:])
        #expect((studio.session.track("t1")?.clips.last?.length.count ?? 0) > 0)
        #expect(await waitForPeaks(studio) != nil)
        #expect(blocks.calls > before)
    }

    /// Plan gate 1 item 1: a pass that waits during a take never holds `settle()`.
    @Test @MainActor func settleEndsATakeWhileAPassWaits() async throws {
        let fixture = try await PeakPackage.make()
        let gate = AsyncGate()
        var studio: Studio? = try await fixture.studio { await gate.wait() }
        await gate.entered()
        try await record(studio!)
        gate.open()
        try await Task.sleep(for: .milliseconds(300))
        let done = StepCounter()

        Task { @MainActor [studio] in
            await studio?.settle()
            _ = done.next()
        }
        await until(limit: .seconds(5), "settle() did not return") { done.calls > 0 }

        #expect(studio?.transport == .idle)
        #expect(!takeFiles(studio!).isEmpty, "the take finalized")
        studio = nil
        _ = try await Studio.open(fixture.url)
    }

    /// No block starts after `settle()` begins. The pass is held in block 1 until settle waits
    /// for its save retry; then the pass reaches its next pause while settle runs.
    @Test @MainActor func noBlockStartsAfterSettleBegins() async throws {
        let fixture = try await PeakPackage.make()
        let (blockGate, saveGate, blocks, saves) = (AsyncGate(), Gate(), StepCounter(), StepCounter(fails: { $0 == 1 }))
        let studio = try await fixture.studio {
            _ = blocks.next()
            await blockGate.wait()
        }
        studio.environment.saveSession = { session, lock throws(SessionFileError) in
            if saves.next() { throw .packageMoved }
            saveGate.waitOnce()
            return try session.write(under: lock)
        }
        await blockGate.entered()
        try studio.edit { session throws(SessionError) in try session.renameTrack("t1", to: "Host") }
        await until(limit: .seconds(10), "the autosave did not fail") { studio.saveError != nil }
        let before = blocks.calls
        let done = StepCounter()

        Task { @MainActor in
            await studio.settle()
            _ = done.next()
        }
        await saveGate.entered()
        blockGate.open()
        try await Task.sleep(for: .milliseconds(300))
        saveGate.open()
        await until(limit: .seconds(10), "settle() did not return") { done.calls > 0 }

        #expect(blocks.calls == before)
        #expect(studio.saveError == nil)
    }

    /// Holds block 1 of the pass in `gate` and then 300 ms, and runs `settle()` in a task that
    /// counts its end in `done`. Opens the gate when settle has begun.
    @MainActor
    func settleDuringBlockOne(_ fixture: PeakPackage) async throws -> (Studio, StepCounter, StepCounter) {
        let (gate, blocks, done) = (AsyncGate(), StepCounter(), StepCounter())
        let studio = try await fixture.studio {
            _ = blocks.next()
            await gate.wait()
            try? await Task.sleep(for: .milliseconds(300))
        }
        await gate.entered()
        Task { @MainActor in
            await studio.settle()
            _ = done.next()
        }
        await until(limit: .seconds(10), "settle did not begin") { studio.peakLoad.settling }
        gate.open()
        await until(limit: .seconds(10), "settle() did not return") { done.calls > 0 }
        return (studio, blocks, done)
    }

    /// A close during a compute: `settle()` ends the pass, so an open at once succeeds.
    @Test @MainActor func reopenAtOnceAfterACloseDuringACompute() async throws {
        let fixture = try await PeakPackage.make()
        var (studio, blocks, _): (Studio?, StepCounter, StepCounter) = try await settleDuringBlockOne(fixture)
        studio = nil
        let after = blocks.calls

        _ = try await Studio.open(fixture.url)
        try await Task.sleep(for: .milliseconds(400))
        #expect(blocks.calls == after, "the compute ended")
    }

    /// Plan gate 2 item 5: the pass checks `settling` at each file start, also for cache hits.
    @Test @MainActor func settleStopsACacheHitLoadAtAFileStart() async throws {
        let ids = (1...20).map { FileID("f\($0)") }
        let fixture = try await PeakPackage.make(files: ids)
        var first: Studio? = try await fixture.studio()
        for id in ids { _ = await waitForPeaks(first!, id) }
        await first?.settle()
        first = nil
        #expect(fixture.cacheFiles().count == 20)

        var studio: Studio? = try await fixture.studio()
        await studio?.settle()

        #expect(ids.filter { peaksOf(studio!, $0) != nil }.count < 20)
        studio = nil
        _ = try await Studio.open(fixture.url)
    }

    /// Plan gate 1 item 2: Stop-and-Close during a take. The finalize in settle starts no pass,
    /// so the new files have no entry.
    @Test @MainActor func aFinalizeDuringSettleStartsNoPass() async throws {
        let fixture = try await PeakPackage.make()
        var studio: Studio? = try await fixture.studio()
        _ = await waitForPeaks(studio!)
        try await record(studio!)

        await studio?.settle()

        let files = takeFiles(studio!)
        #expect(!files.isEmpty)
        #expect(files.allSatisfy { studio?.peaks[$0] == nil }, "\(files.map { studio?.peaks[$0] })")
        studio = nil
        _ = try await Studio.open(fixture.url)
    }

    /// The window calls `loadPeaks()` when the user cancels the close.
    @Test @MainActor func aCancelledCloseLoadsPeaksAgain() async throws {
        let fixture = try await PeakPackage.make()
        let studio = try await fixture.studio()
        _ = await waitForPeaks(studio)
        try await record(studio)
        await studio.settle()

        studio.loadPeaks()

        let files = takeFiles(studio)
        #expect(!files.isEmpty)
        for id in files { #expect(await waitForPeaks(studio, id) != nil) }
    }

    /// Plan gate 2 item 4: a settle with no save error also ends the pass and clears `settling`.
    @Test @MainActor func aSettleWithNoSaveErrorClearsSettling() async throws {
        let fixture = try await PeakPackage.make()
        let (studio, _, _) = try await settleDuringBlockOne(fixture)
        #expect(studio.saveError == nil)

        studio.loadPeaks()

        #expect(await waitForPeaks(studio) != nil)
    }

    /// Plan gate 1 item 3: Studio starts the pass after a finalize, with no call from the window.
    @Test @MainActor func aFinalizedTakeReachesReadyWithNoFocus() async throws {
        let fixture = try await PeakPackage.make()
        let studio = try await fixture.studio()
        _ = await waitForPeaks(studio)
        try await record(studio)

        try await studio.stopRecording()

        let files = takeFiles(studio)
        #expect(!files.isEmpty)
        for id in files { #expect(await waitForPeaks(studio, id) != nil) }
    }

    /// A read error during a compute (probe-read-error: -40, no errno): the hook of block 2
    /// detaches the volume. The file gets `.unavailable` and `.unreadable` in `missingMedia`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    @MainActor func aReadErrorGivesUnavailableAndAFault() async throws {
        let fixture = try await PeakPackage.make()
        let folder = try TemporaryFolder()
        let (image, volume) = (folder.url.appending(path: "gone.dmg"), folder.url.appending(path: "volume"))
        try await offMainActor {
            try FullDiskTests.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigiblePeaks", image.path)
            try FullDiskTests.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        }
        // The fault detaches the volume, so this detach can fail.
        defer { FullDiskTests.run(["detach", volume.path, "-force"]) }
        let package = volume.appending(path: "Show.dirigible")
        try FileManager.default.copyItem(at: fixture.url, to: package)
        let blocks = StepCounter()

        let studio = try await fixture.studio(at: package) {
            _ = blocks.next()
            if blocks.calls == 2 { FullDiskTests.run(["detach", volume.path, "-force"]) }
        }

        await until(limit: .seconds(30), "f1 is not unavailable") { studio.peaks["f1"] == .unavailable }
        #expect(blocks.calls == 2)
        #expect(studio.missingMedia["f1"] == .unreadable)
    }
}
