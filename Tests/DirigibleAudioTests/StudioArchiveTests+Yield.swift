import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The waits and the yields of the studio archive job (decision 0072, run criteria C15 and C19).
extension StudioArchiveTests {
    /// Holds the raw sweep of `studio` at `.first` until `gate` opens. `cancelled` gets true when
    /// a caller cancels the held sweep, as the archive does before its wait.
    static func holdSweep(_ studio: Studio, _ gate: AsyncGate, _ cancelled: OSAllocatedUnfairLock<Bool>) {
        studio.environment.beforeRawStep = { step in
            guard step == .first else { return }
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
        }
    }

    /// C15: the archive cancels a held raw sweep and starts no file step until the sweep ends, and
    /// no CAF goes during the job. After the archive the segment of the old take has the verdict
    /// `.archived` and keeps its CAF; after the unarchive it has the verdict of before.
    @Test func theArchiveWaitsForTheRawSweep() async throws {
        let (package, _) = try await RawSweepTests.oldTake()
        let studio = try await Studio.open(package.url)
        let (gate, cancelled) = (AsyncGate(), OSAllocatedUnfairLock(initialState: false))
        defer { gate.open() }
        Self.holdSweep(studio, gate, cancelled)
        await gate.entered()
        let before = rawCaptures(of: studio.session, in: package.url)
        let blocks = OSAllocatedUnfairLock(initialState: 0)
        studio.environment.archiveBlock = { blocks.withLock { $0 += 1 } }
        let session = try Data(contentsOf: package.url.appending(path: "session.xml"))

        let job = Task { try await studio.archive { _ in } }
        await until(limit: .seconds(10), "the archive did not stop the sweep") { cancelled.withLock { $0 } }

        #expect(blocks.withLock { $0 } == 0, "the archive read a file during the held sweep")
        #expect(try Data(contentsOf: package.url.appending(path: "session.xml")) == session, "a save before the wait")
        gate.open()
        _ = try await job.value

        #expect(blocks.withLock { $0 } > 0, "the archive converted no file")
        #expect(RawSweepTests.hasCAF(package), "a CAF went during the archive")
        #expect(rawCaptures(of: studio.session, in: package.url) == [RawSweepTests.segment: .archived])

        _ = try await studio.unarchive { _ in }

        #expect(RawSweepTests.hasCAF(package))
        #expect(before == [RawSweepTests.segment: .removable], "\(before)")
        #expect(rawCaptures(of: studio.session, in: package.url) == before)
        await studio.settle()
    }

    /// C19 (c): a take start in another studio while the archive waits for the raw sweep makes the
    /// archive throw `.busy` after the wait, and no file changes.
    @Test func aTakeStartDuringTheSweepWaitMakesTheArchiveBusy() async throws {
        let (package, _) = try await RawSweepTests.oldTake()
        let studioB = try await Studio.open(package.url)
        let (gate, cancelled) = (AsyncGate(), OSAllocatedUnfairLock(initialState: false))
        defer { gate.open() }
        Self.holdSweep(studioB, gate, cancelled)
        await gate.entered()
        let files = try Self.packageBytes(package.url)
        let job = Task { try await studioB.archive { _ in } }
        await until(limit: .seconds(10), "the archive did not stop the sweep") { cancelled.withLock { $0 } }
        let a = try await ExportStudioFixture.make()
        let hal = TestHAL([a.mic])
        let studioA = try await a.open(hal)
        studioA.otherStudios = { [studioB] }
        studioB.otherStudios = { [studioA] }

        let start = Task { try await studioA.startTake(armed: ["t1"], devices: [a.mic], hostTimeNanos: takeStart) }
        await until(limit: .seconds(10), "the take start did not begin") {
            studioA.isStarting || studioA.transport == .recording(take: 1)
        }
        gate.open()

        await #expect(throws: StudioError.busy) { try await job.value }
        #expect(try Self.packageBytes(package.url) == files, "the refused archive changed a file")
        _ = try await start.value
        try await StudioExportTests().recordAndStop(studioA, hal, from: takeStart)
        await studioB.settle()
    }

    /// C19 (c): an export that the test queues during the file loop throws `.busy` and writes no
    /// file, and the job goes on to convert each file.
    @Test func anExportDuringTheFileLoopIsBusy() async throws {
        let fixture = try await ArchiveStudioFixture.make()
        let studio = try await fixture.open()
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let hold = ChunkSeam(at: [1: { gate.waitOnce() }])
        studio.environment.archiveBlock = { hold.step() }
        let job = Task { try await studio.archive { _ in } }
        await gate.entered()
        let out = fixture.package.folder.url.appending(path: "mix.wav")

        await #expect(throws: StudioError.busy) {
            try await studio.export(
                ExportSource(range: 0..<48_000)!, ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .session),
                to: out, replacing: nil)
        }
        gate.open()
        _ = try await job.value

        #expect(!FileManager.default.fileExists(atPath: out.path), "the refused export wrote its file")
        #expect(fixture.clipsNames == ["f1.flac", "f2.flac", "f3.flac"], "the export stopped the archive")
    }

    /// C19 (b): the disk check of a take in A ends the archive of B on the volume, and that check
    /// does not stop the take. B does not list A, so its archive starts during the take.
    @Test func theDiskCheckOfATakeEndsAnArchiveOnItsVolume() async throws {
        let a = try await ExportStudioFixture.make()
        let studioA = try await a.open(TestHAL([a.mic]))
        // One read of no free space after the test sets `low`, then 100 GB again.
        let low = OSAllocatedUnfairLock(initialState: false)
        studioA.environment.freeBytes = { _ in
            low.withLock { isLow in
                defer { isLow = false }
                return isLow
            } ? 0 : 100_000_000_000
        }
        let b = try await ArchiveStudioFixture.make()
        let studioB = try await b.open()
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let hold = ChunkSeam(at: [1: { gate.waitOnce() }])
        studioB.environment.archiveBlock = { hold.step() }
        studioA.otherStudios = { [studioB] }
        try await studioA.startRecording(armed: ["t1"])
        let job = Task { try await studioB.archive { _ in } }
        await gate.entered()

        low.withLock { $0 = true }
        await until(limit: .seconds(30), "the disk check did not end the archive") { studioB.archiveStop == .take }
        gate.open()

        await #expect(throws: StudioError.archive(.cancelled)) { try await job.value }
        #expect(studioA.transport == .recording(take: 1), "the disk check stopped the take")
        #expect(b.clipsNames == ["f1.wav", "f2.wav", "f3.wav"], "the file in hand changed its form")
        #expect(needsUnarchive(try b.stored()), "the package lost its attribute")
        try await studioA.stopRecording()
        #expect(studioA.lastTake?.end != .diskLow)
    }

    /// The bytes of `session.xml` and of each file of `Clips/` and `Capture/`.
    static func packageBytes(_ package: URL) throws -> [String: Data] {
        var files: [String: Data] = ["session.xml": try Data(contentsOf: package.appending(path: "session.xml"))]
        for folder in [clipsFolderName, "Capture"] {
            let names = try FileManager.default.contentsOfDirectory(atPath: package.appending(path: folder).path)
            for name in names {
                files["\(folder)/\(name)"] = try Data(contentsOf: package.appending(path: "\(folder)/\(name)"))
            }
        }
        return files
    }
}
