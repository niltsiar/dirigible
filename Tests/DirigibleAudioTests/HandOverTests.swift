import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The hand-over of the monitor to a take and its come back after the take (decision 0015).
/// The fixture is in `MonitorTests`.
extension MonitorTests {
    /// Monitors `t1` and waits for the attach of its input.
    func monitorT1(_ studio: Studio, _ hal: TestHAL) async throws -> DeviceInput? {
        try await studio.monitor(armed: ["t1"])
        await until(limit: busy, "no monitor attach") { hal.current("duo") != nil }
        return hal.current("duo")
    }

    // MARK: Criterion 4

    @Test func aTakeAttachesBeforeTheMonitorReleases() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo])
        let studio = try await open(url, hal)
        let monitor = try #require(try await monitorT1(studio, hal))

        // Each 1 ms on the main actor: is the entry of t1 there?
        let missing = LockedBox<Int>()
        let watching = LockedBox<Bool>()
        watching.value = true
        let watcher = Task { @MainActor in
            while watching.value == true {
                if studio.liveTracks["t1"] == nil { missing.value = (missing.value ?? 0) + 1 }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        let take = try #require(hal.inputs("duo").last)
        #expect(take !== monitor)
        #expect(hal.events("duo") == [.attach(monitor), .attach(take), .detach(monitor)])
        #expect(studio.liveTracks["t1"]?.state == .recording)
        watching.value = false
        await watcher.value
        #expect(missing.value == nil)

        try await studio.stopRecording()
        await studio.settle()
        _ = folder
    }

    // MARK: Criterion 5

    /// Control: with an empty request before the stop, no attach comes after it.
    @Test(arguments: [true, false])
    func theMonitorComesBackAfterATake(requested: Bool) async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo])
        let studio = try await open(url, hal)
        _ = try await monitorT1(studio, hal)
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        if !requested { try await studio.monitor(armed: []) }

        try await studio.stopRecording()

        guard requested else {
            #expect(hal.inputs("duo").count == 2)
            #expect(hal.current("duo") == nil)
            #expect(studio.liveTracks.isEmpty)
            await studio.settle()
            return
        }
        await until(limit: busy, "no attach after the take") {
            hal.inputs("duo").count == 3 && hal.current("duo") != nil
        }
        #expect(studio.liveTracks["t1"]?.state == .monitoring)
        SyntheticInput(hal, "duo").play(await toneRecords(), pace: .realTime)
        await until(limit: busy, "no peak after the take") { abs(peak(studio, "t1") - 0.5) <= 0.01 }
        await studio.settle()
        #expect(hal.current("duo") == nil)
        _ = folder
    }

    // MARK: Criterion 6

    /// Control: criterion 4, a start that succeeds releases the monitor.
    @Test func aStartThatThrowsKeepsTheMonitor() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo])
        let studio = try await Studio.open(url)
        studio.environment = .test(hal, free: FreeBytes(500_000_000))
        let monitor = try #require(try await monitorT1(studio, hal))

        await #expect(throws: StudioError.diskLow) { try await studio.startRecording(armed: ["t1"], playhead: 0) }

        #expect(hal.current("duo") === monitor)
        #expect(hal.tries("duo").count == 1)
        #expect(studio.liveTracks["t1"]?.state == .monitoring)
        await studio.settle()
        _ = folder
    }

    // MARK: Criterion 7

    @Test func aRequestDuringATakeStartsAfterIt() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo])
        let studio = try await open(url, hal)
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        await until(limit: busy, "no take attach") { hal.inputs("duo").count == 1 }

        try await studio.monitor(armed: ["t1"])
        #expect(studio.monitorWriter("duo") == nil)
        #expect(studio.liveTracks["t1"]?.state == .recording)

        try await studio.stopRecording()
        await until(limit: busy, "no monitor after the take") {
            hal.inputs("duo").count == 2 && hal.current("duo") != nil
        }
        #expect(studio.liveTracks["t1"]?.state == .monitoring)
        await studio.settle()
        _ = folder
    }

    // MARK: Criterion 21

    /// The finalize waits on a closed gate. Control in the same test: the monitor holds the
    /// device during the finalize until the toggle goes off.
    @Test func aToggleOffDuringAFinalizeReleasesAtOnce() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo])
        let gate = Gate()
        let studio = try await Studio.open(url)
        studio.environment = .test(hal, beforeFinalize: { gate.waitOnce() })
        _ = try await monitorT1(studio, hal)
        try await studio.startRecording(armed: ["t1"], playhead: 0)

        let stop = Task { try await studio.stopRecording() }
        await gate.entered()
        #expect(studio.transport == .finalizing(take: 1))
        #expect(studio.liveTracks["t1"]?.state == .monitoring)
        await until(limit: busy, "no monitor during the finalize") { hal.current("duo") != nil }

        let released = LockedBox<Bool>()
        let off = Task { @MainActor in
            try await studio.monitor(armed: [])
            released.value = true
        }
        await until(limit: busy, "the toggle off waits for the finalize") { released.value == true }
        #expect(hal.current("duo") == nil)
        #expect(studio.transport == .finalizing(take: 1))

        gate.open()
        try await off.value
        try await stop.value
        #expect(studio.transport == .idle)
        _ = folder
    }

    // MARK: Criterion 22

    /// Control: `isStarting` is false while the first attach of the take writer is held.
    @Test func aStopDuringTheHandOverWaitsForIt() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo])
        let studio = try await open(url, hal)
        _ = try await monitorT1(studio, hal)
        hal.holdAttaches()

        let start = Task { try await studio.startRecording(armed: ["t1"], playhead: 0) }
        await until(limit: busy, "the take did not begin") { studio.transport == .recording(take: 1) }
        #expect(!studio.isStarting)
        let stop = Task { try await studio.stopRecording() }
        await until(limit: busy, "the stop did not begin") { studio.transport == .finalizing(take: 1) }
        hal.releaseAttaches()

        try await start.value
        try await stop.value
        #expect(studio.transport == .idle)
        await until(limit: busy, "no monitor after the take") {
            hal.inputs("duo").count == 3 && hal.current("duo") != nil
        }
        #expect(studio.liveTracks["t1"]?.state == .monitoring)
        await studio.settle()
        _ = folder
    }
}
