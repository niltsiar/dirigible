import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The write chain of decision 0014 (record-ui criteria 1, 2, 3, 19, and 20): each edit saves
/// off the main actor, and no write lands after a later one.
@MainActor
struct AutosaveTests {
    let folder: TemporaryFolder
    let url: URL
    var sessionXML: URL { url.appending(path: "session.xml") }
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    /// Track `t1` on channel 1 of `mic`.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRoute(Route(deviceUID: "mic", channels: .mono(1)), track: "t1")
        try session.write(to: url)
    }

    func studio(
        _ hal: TestHAL = TestHAL([]),
        save: @escaping @Sendable (Session, PackageLock) async throws(SessionFileError) -> URL = CaptureEnvironment.live
            .saveSession
    ) async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(hal, saveSession: save)
        return studio
    }

    func rename(_ studio: Studio, to name: String) throws {
        try studio.edit { session throws(SessionError) in try session.renameTrack("t1", to: name) }
    }

    // MARK: Criterion 2

    @Test func anOldAutosaveNeverLandsAfterTheRecordingSave() async throws {
        let gate = AsyncGate()
        let studio = try await studio(TestHAL([mic])) { session, lock throws(SessionFileError) in
            await gate.wait()
            return try session.write(under: lock)
        }
        try rename(studio, to: "Guest")
        await gate.entered()

        async let start: Void = studio.startRecording(armed: ["t1"], playhead: 0)
        await until(limit: .seconds(30), "the start waits for the chain") { studio.isStarting }
        gate.open()
        try await start

        let saved = try Session(contentsOf: url)
        #expect(saved.recording != nil)
        #expect(saved.track("t1")?.name == "Guest")
        await studio.settle()
    }

    /// Control of the ordering test: no write in progress, and the start saves `<recording>`.
    @Test func aStartWithNoAutosaveInProgressSavesRecording() async throws {
        let studio = try await studio(TestHAL([mic]))

        try await studio.startRecording(armed: ["t1"], playhead: 0)

        #expect(try Session(contentsOf: url).recording != nil)
        await studio.settle()
    }

    // MARK: Criterion 1

    @Test func eachEditUndoAndRedoIsSaved() async throws {
        let studio = try await studio()

        try rename(studio, to: "Guest")
        await studio.settle()
        #expect(try Session(contentsOf: url) == studio.session)
        #expect(studio.session.track("t1")?.name == "Guest")

        try studio.undo()
        await studio.settle()
        #expect(try Session(contentsOf: url).track("t1")?.name == "Host")

        try studio.redo()
        await studio.settle()
        #expect(try Session(contentsOf: url).track("t1")?.name == "Guest")
    }

    /// Control: an edit that throws starts no write.
    @Test func aRefusedEditWritesNothing() async throws {
        let calls = StepCounter()
        let studio = try await studio { session, lock throws(SessionFileError) in
            _ = calls.next()
            return try session.write(under: lock)
        }
        let before = try Data(contentsOf: sessionXML)

        #expect(throws: StudioError.session(.invalidText("A\u{0}B"))) { try rename(studio, to: "A\u{0}B") }
        await studio.settle()

        #expect(try Data(contentsOf: sessionXML) == before)
        #expect(calls.calls == 0)
    }

    /// Edit-commands criterion 18 (a held Nudge key): 50 edits make at most 2 writes, and the
    /// last session reaches the disk. Controls: a write for each edit makes 50; a skip of the edits
    /// that come during a write in progress leaves "Name 1" on disk.
    @Test func fiftyEditsGiveAtMostTwoWrites() async throws {
        let gate = AsyncGate()
        let calls = StepCounter()
        let studio = try await studio { session, lock throws(SessionFileError) in
            _ = calls.next()
            await gate.wait()
            return try session.write(under: lock)
        }

        try rename(studio, to: "Name 1")
        await gate.entered()
        for n in 2...50 { try rename(studio, to: "Name \(n)") }
        gate.open()
        await studio.settle()

        #expect(calls.calls <= 2)
        #expect(try Session(contentsOf: url) == studio.session)
        #expect(studio.session.track("t1")?.name == "Name 50")
    }

    // MARK: Criterion 3

    @Test func anEditReturnsBeforeItsWrite() async throws {
        let studio = try await studio { session, lock throws(SessionFileError) in
            try? await Task.sleep(for: .milliseconds(300))
            return try session.write(under: lock)
        }

        let clock = ContinuousClock()
        let edit = try clock.measure { try rename(studio, to: "Guest") }
        let settle = await clock.measure { await studio.settle() }

        #expect(edit < .milliseconds(100))
        // Control: the write did run.
        #expect(settle >= .milliseconds(300))
        #expect(try Session(contentsOf: url).track("t1")?.name == "Guest")
    }

    // MARK: Criterion 19

    @Test func settleStopsATakeAndWaitsForItsFinalize() async throws {
        let hal = TestHAL([mic])
        let studio = try await studio(hal)
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock(hostNanos: Double(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())))
        input.play(clock.run(seconds: 1))
        await input.wait()

        await studio.settle()

        #expect(studio.transport == .idle)
        #expect(studio.session.track("t1")?.clips.count == 1)
        #expect(try Session(contentsOf: url).recording == nil)
        #expect(try Session(contentsOf: url) == studio.session)
    }

    @Test func settleWaitsForAFinalizeInProgress() async throws {
        let studio = try await studio(TestHAL([mic]))
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        let stop = Task { try await studio.stopRecording() }
        // Bounded, so a regression fails the test instead of a hang.
        for _ in 0..<10_000 where studio.transport != .finalizing(take: 1) { await Task.yield() }
        try #require(studio.transport == .finalizing(take: 1))

        await studio.settle()

        #expect(studio.transport == .idle)
        #expect(try Session(contentsOf: url).recording == nil)
        try await stop.value
    }

    /// Control: with no take and no write, settle changes no file.
    @Test func settleWithNothingToDoChangesNoFile() async throws {
        let studio = try await studio()
        let before = try Data(contentsOf: sessionXML)
        let modified = try FileManager.default.attributesOfItem(atPath: sessionXML.path)[.modificationDate] as? Date

        await studio.settle()

        #expect(try Data(contentsOf: sessionXML) == before)
        #expect(
            try FileManager.default.attributesOfItem(atPath: sessionXML.path)[.modificationDate] as? Date == modified)
        #expect(studio.saveError == nil)
    }

    @Test func settleWritesAFailedAutosaveOnceMore() async throws {
        let calls = StepCounter { $0 == 1 }
        let studio = try await studio { session, lock throws(SessionFileError) in
            if calls.next() { throw .writeFailed(step: "test", errno: EIO) }
            return try session.write(under: lock)
        }

        try rename(studio, to: "Guest")
        await studio.settle()

        #expect(try Session(contentsOf: url).track("t1")?.name == "Guest")
        #expect(studio.saveError == nil)
        #expect(calls.calls == 2)
    }

    /// Control: the write in settle also fails, so the error stays, and settle writes once more
    /// only.
    @Test func settleKeepsTheErrorWhenTheRetryFails() async throws {
        let calls = StepCounter { _ in true }
        let studio = try await studio { _, _ throws(SessionFileError) -> URL in
            _ = calls.next()
            throw .writeFailed(step: "test", errno: EIO)
        }
        let before = try Data(contentsOf: sessionXML)

        try rename(studio, to: "Guest")
        await studio.settle()

        #expect(studio.saveError == .file(.writeFailed(step: "test", errno: EIO)))
        #expect(try Data(contentsOf: sessionXML) == before)
        #expect(calls.calls == 2)
    }

    // MARK: Criterion 20

    @Test func anAutosaveErrorShowsUntilTheNextGoodSave() async throws {
        let calls = StepCounter { $0 == 1 }
        let studio = try await studio { session, lock throws(SessionFileError) in
            if calls.next() { throw .writeFailed(step: "test", errno: ENOSPC) }
            return try session.write(under: lock)
        }

        try rename(studio, to: "Guest")
        await until(limit: .seconds(30), "the first autosave did not fail") { studio.saveError != nil }
        #expect(studio.saveError == .file(.writeFailed(step: "test", errno: ENOSPC)))

        try rename(studio, to: "Band")
        await until(limit: .seconds(30), "the second autosave did not clear the error") { studio.saveError == nil }
        await studio.settle()

        #expect(try Session(contentsOf: url).track("t1")?.name == "Band")
        #expect(calls.calls == 2)
    }

    /// Control: with no fault, the error stays nil.
    @Test func aGoodAutosaveHasNoError() async throws {
        let studio = try await studio()

        try rename(studio, to: "Guest")
        await studio.settle()

        #expect(studio.saveError == nil)
    }
}
