import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The revert guards of decision 0043 (run 14, criteria C10 to C12, C23, and C24).
extension StudioBackupTests {
    /// A take package whose take 1 stays pending: a closed segment and a recovery marker.
    func pendingTakePackage() async throws -> (TakePackage, Studio) {
        let package = try TakePackage()
        try package.segment(samples: sine(seconds: 2, rate: 48_000))
        FileManager.default.createFile(atPath: package.url.appending(path: "recovery-attempt").path, contents: nil)
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([]))
        try #require(studio.pendingTake?.take == 1)
        return (package, studio)
    }

    /// C10: the revert keeps the pending take, and the retry places it after the revert.
    @Test func aRevertKeepsAPendingTake() async throws {
        let (package, studio) = try await pendingTakePackage()
        var old = Session(sampleRate: 48_000)
        try old.addTrack("t1", name: "Old", layout: .mono)
        let backup = try plant(old, at: 1_000_000, in: package.url)

        try await studio.revert(to: backup)

        #expect(studio.pendingTake?.take == 1, "the revert keeps the pending take")
        #expect(studio.session.track("t1")?.name == "Old")
        try await studio.retryFinalize()
        #expect(studio.pendingTake == nil)
        #expect(studio.session.track("t1")?.clips.map(\.id) == ["take1-1-1"])
        await studio.settle()
    }

    /// C10: a backup with no armed track throws, and nothing changes.
    @Test func aRevertThatRemovesAnArmedTrackChangesNothing() async throws {
        let (package, studio) = try await pendingTakePackage()
        let backup = try plant(Session(sampleRate: 48_000), at: 1_000_000, in: package.url)
        let (session, revision) = (studio.session, studio.sessionRevision)
        let saved = try Data(contentsOf: package.url.appending(path: "session.xml"))

        await #expect(
            throws: StudioError.session(.trackInRecording("t1")), "the revert refuses a backup with no armed track"
        ) {
            try await studio.revert(to: backup)
        }

        #expect(studio.session == session && studio.sessionRevision == revision && !studio.canUndo)
        #expect(try Data(contentsOf: package.url.appending(path: "session.xml")) == saved)
        await studio.settle()
    }

    /// The bytes of each file in `Clips/` and `Capture/` of `package`, by relative path.
    func audioFiles(_ package: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for folder in ["Clips", "Capture"] {
            for name in try FileManager.default.contentsOfDirectory(atPath: package.appending(path: folder).path) {
                files["\(folder)/\(name)"] = try Data(contentsOf: package.appending(path: "\(folder)/\(name)"))
            }
        }
        return files
    }

    /// C11: a revert to the backup of the state before a take deletes no audio. The take segment
    /// is unplaced; Undo gives the clip back.
    @Test func aRevertBeforeATakeLeavesItsAudioUnplaced() async throws {
        let package = try TakePackage()
        try package.segment(samples: sine(seconds: 2, rate: 48_000))
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([]))
        let segment = SegmentName(take: 1, arm: 1, segment: 1)
        try #require(studio.session.track("t1")?.clips.count == 1)
        let backup = try #require(studio.backups.first, "the recovery save keeps the state before the take")
        let before = try audioFiles(package.url)

        try await studio.revert(to: backup)

        #expect(studio.unplacedSegments == [segment], "the take segment is unplaced")
        #expect(studio.session.track("t1")?.clips.count == 0)
        #expect(try audioFiles(package.url) == before, "the revert deletes no audio")
        try studio.undo()
        #expect(studio.session.track("t1")?.clips.count == 1)
        #expect(studio.unplacedSegments == [])
        try studio.redo()
        _ = try await studio.place(segment)
        #expect(studio.session.track("t1")?.clips.count == 1)
        await studio.settle()
    }

    /// C12: busy during a take, a finalize, an import, and a take that starts during the read.
    /// Control: the same revert when idle works.
    @Test func aRevertWhileBusyChangesNothing() async throws {
        let gate = AsyncGate()
        let saveGate = AsyncGate()
        let studio = try await studio(
            TestHAL([mic]),
            save: { session, lock throws(SessionFileError) in
                await saveGate.wait()
                return try session.write(under: lock)
            },
            beforeFinalize: { await gate.wait() })
        let backup = try plant(Self.named("A"), at: try sessionTime() - 1)
        let before = names()

        try await studio.startRecording(armed: ["t1"], playhead: 0)
        await #expect(throws: StudioError.busy, "busy during a take") { try await studio.revert(to: backup) }
        #expect(names() == before, "a revert during a take adds no backup file")
        let stop = Task { try await studio.stopRecording() }
        await gate.entered()
        await #expect(throws: StudioError.busy, "busy during a finalize") { try await studio.revert(to: backup) }
        gate.open()
        try await stop.value
        studio.transport = .importing(ImportRun(name: "Voice.wav", kind: .file, flags: ImportFlags()))
        await #expect(throws: StudioError.busy, "busy during an import") { try await studio.revert(to: backup) }
        studio.transport = .idle

        try setName(studio, to: "B")
        await saveGate.entered()
        let revert = Task { try await studio.revert(to: backup) }
        await until(limit: .seconds(20), "the revert waits for the save") { studio.writesWaiting == 1 }
        let start = Task { try await studio.startRecording(armed: ["t1"], playhead: 0) }
        await until(limit: .seconds(20), "the start waits") { studio.isStarting }
        saveGate.open()
        await #expect(throws: StudioError.busy, "a take that starts during the read") { try await revert.value }
        #expect(studio.session.track("t1")?.name == "B")
        try await start.value
        try await studio.stopRecording()

        await #expect(throws: Never.self, "an idle revert works") { try await studio.revert(to: backup) }
        #expect(studio.session.track("t1")?.name == "A")
        await studio.settle()
    }

    /// C23: a revert after a failed save throws the save error; after a good save it works.
    @Test func aRevertWaitsForAGoodSave() async throws {
        let failures = LockedBox<Int>()
        let studio = try await studio(save: { session, lock throws(SessionFileError) in
            failures.value = (failures.value ?? 0) + 1
            if failures.value == 1 { throw .writeFailed(step: "write", errno: ENOSPC) }
            return try session.write(under: lock)
        })
        let backup = try plant(Self.named("A"), at: try sessionTime() - 1)
        try setName(studio, to: "B")
        await studio.serialized {}
        let before = names()

        await #expect(
            throws: StudioError.file(.writeFailed(step: "write", errno: ENOSPC)), "the revert waits for a good save"
        ) {
            try await studio.revert(to: backup)
        }

        #expect(names() == before, "a revert over an unsaved state adds no file")
        #expect(studio.session.track("t1")?.name == "B")
        try setName(studio, to: "C")
        await studio.serialized {}
        try await studio.revert(to: backup)
        #expect(studio.session.track("t1")?.name == "A")
        await studio.settle()
    }

    /// C23: a save that fails while the revert waits for its turn stops the revert.
    @Test func aSaveThatFailsDuringTheWaitStopsTheRevert() async throws {
        let gate = AsyncGate()
        let studio = try await studio(save: { _, _ throws(SessionFileError) in
            await gate.wait()
            throw .writeFailed(step: "write", errno: ENOSPC)
        })
        let backup = try plant(Self.named("A"), at: try sessionTime() - 1)
        let before = names()
        try setName(studio, to: "B")
        await gate.entered()

        let revert = Task { try await studio.revert(to: backup) }
        await until(limit: .seconds(20), "the revert waits for the save") { studio.writesWaiting == 1 }
        gate.open()

        await #expect(
            throws: StudioError.file(.writeFailed(step: "write", errno: ENOSPC)), "the failed save stops the revert"
        ) {
            try await revert.value
        }
        #expect(names() == before, "the stopped revert adds no file")
        #expect(studio.session.track("t1")?.name == "B")
    }

    /// An edit while the revert waits for its turn is not in the copy that the revert keeps, so
    /// the revert stops and the edit stays (code gate 1 item 3).
    @Test func anEditDuringTheWaitStopsTheRevert() async throws {
        let gate = AsyncGate()
        let studio = try await studio(save: { session, lock throws(SessionFileError) in
            await gate.wait()
            return try session.write(under: lock)
        })
        let backup = try plant(Self.named("A"), at: try sessionTime() - 1)
        try setName(studio, to: "B")
        await gate.entered()

        let revert = Task { try await studio.revert(to: backup) }
        await until(limit: .seconds(20), "the revert waits for the save") { studio.writesWaiting == 1 }
        try setName(studio, to: "C")
        gate.open()

        await #expect(throws: StudioError.busy, "an edit during the wait stops the revert") {
            try await revert.value
        }
        #expect(studio.session.track("t1")?.name == "C", "the edit stays")
        await studio.settle()
    }

    /// An Undo before the turn of the revert is on the disk, and a Redo during the turn sets
    /// the session back to its value at the call. The kept copy has the undone state, so the
    /// revert stops (fix check of code gate 1, item 3).
    @Test func anUndoAndRedoDuringTheWaitStopTheRevert() async throws {
        let (first, second, steps) = (AsyncGate(), AsyncGate(), StepCounter())
        let studio = try await studio(save: { session, lock throws(SessionFileError) in
            _ = steps.next()
            let call = steps.calls
            if call == 1 { await first.wait() }
            let url = try session.write(under: lock)
            if call == 2 { await second.wait() }
            return url
        })
        let backup = try plant(Self.named("A"), at: try sessionTime() - 1)
        try setName(studio, to: "B")
        await first.entered()
        try setName(studio, to: "C")

        let revert = Task { try await studio.revert(to: backup) }
        await until(limit: .seconds(20), "the save and the revert wait") { studio.writesWaiting == 2 }
        try studio.undo()
        first.open()
        await second.entered()
        try studio.redo()
        second.open()

        await #expect(throws: StudioError.busy, "an undo and a redo during the wait stop the revert") {
            try await revert.value
        }
        #expect(studio.session.track("t1")?.name == "C", "the redo stays")
        await studio.settle()
    }

    /// C24: revert to the oldest of 20 backups, Undo, revert to the next oldest, Undo, close.
    /// With `due`, the last Undo replaces a file 700 s after the kept name, so its save is due.
    /// The contents count, not the names: a due save can move an old backup to a new name.
    func tryBackups(due: Bool) async throws {
        let studio = try await studio()
        let time = try sessionTime()
        let planted = try (1...20).map { try plant(Self.named("v\($0)"), at: time - $0) }
        try setName(studio, to: "E")
        await studio.serialized {}

        try await studio.revert(to: planted[19])
        try #require(studio.session.track("t1")?.name == "v20")
        try studio.undo()
        await studio.serialized {}
        let kept = try #require(Backup(fileName: names().subtracting(planted.map(\.fileName)).first ?? ""))
        try await studio.revert(to: planted[18])
        try #require(studio.session.track("t1")?.name == "v19")
        await studio.serialized {}
        if due { try setSessionTime(Int(kept.saved.timeIntervalSince1970) + 700) }
        try studio.undo()
        await studio.settle()

        let names = names()
        let held = Set(names.compactMap { try? Data(contentsOf: url.appending(path: "Backups/\($0)")) })
        let tried = try Set((1...20).map { try bytes(of: Self.named("v\($0)")) })
        #expect(tried.isSubset(of: held), "trying backups keeps all 20")
        #expect(names.count <= 21, "trying backups adds at most one file")
    }

    @Test func tryingBackupsKeepsThem() async throws { try await tryBackups(due: false) }

    @Test func aDueUndoAfterATryKeepsTheBackups() async throws { try await tryBackups(due: true) }
}
