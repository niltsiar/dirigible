import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// C19: the turn of the job removes a CAF only when `session` is the session on the disk and the
/// files are the ones that the job read. Each case counts the flushes of the removal: each
/// removal flushes before its unlink.
extension RawSweepTests {
    /// Opens `package` with the job held at `at`, and counts the flushes of the removal.
    static func held(
        _ package: TakePackage, at: RawSweepStep, log: DiagnosticLog = .disabled
    ) async throws -> (Studio, Hold, StepCounter) {
        let studio = try await Studio.open(package.url, log: log)
        let (hold, flushes) = (Hold(at: at), StepCounter())
        studio.environment.beforeRawStep = { await hold.step($0) }
        studio.environment.rawFlush = {
            _ = flushes.next()
            return fullFlush(path: $0)
        }
        await hold.gate.entered()
        return (studio, hold, flushes)
    }

    /// One edit of `studio` that throws the error of `body` as `.session`.
    static func edit(_ studio: Studio, _ body: (inout Session) throws(SessionError) -> Void) throws(StudioError) {
        let refused: (StudioError) -> StudioError = { $0 }
        try studio.edit(agent: nil, refused: refused) { session throws(StudioError) in
            do throws(SessionError) { try body(&session) } catch { throw .session(error) }
        }
    }

    static func deleteClips(_ studio: Studio) throws(StudioError) {
        let clips = studio.session.tracks.flatMap(\.clips).map(\.id)
        try edit(studio) { session throws(SessionError) in try session.removeClips(clips) }
    }

    /// C19 (1): a clip delete during the read. Its save ends before the turn, so the gate in the
    /// turn sees the segment unplaced.
    @Test func aClipDeleteDuringABlockedReadKeepsTheCAF() async throws {
        let (package, _) = try await Self.oldTake()
        let (studio, hold, flushes) = try await Self.held(package, at: .block(2))
        defer { hold.gate.open() }

        try Self.deleteClips(studio)
        await studio.serialized {}
        hold.gate.open()
        await studio.rawSweep

        #expect(Self.hasCAF(package) && flushes.calls == 0, "flushes: \(flushes.calls)")
        await studio.settle()
    }

    /// C19 (2): another file replaces the WAV after the read, with the same bytes. The gate passes
    /// in the turn, and the new inode keeps the CAF with one `raw` line.
    @Test func aWAVReplacedAfterTheReadKeepsTheCAF() async throws {
        let (package, _) = try await Self.oldTake()
        let logs = package.folder.url.appending(path: "logs")
        let log = startLog(in: logs)
        let (studio, hold, flushes) = try await Self.held(package, at: .turn, log: log)
        defer { hold.gate.open() }

        let wav = package.url.appending(path: "Clips/\(Self.segment.stem).wav")
        let copy = package.url.appending(path: "Clips/copy.wav")
        try FileManager.default.copyItem(at: wav, to: copy)
        try #require(rename(copy.path, wav.path) == 0)
        hold.gate.open()
        await studio.rawSweep

        #expect(Self.hasCAF(package) && flushes.calls == 0, "flushes: \(flushes.calls)")
        let raw = TakeLogTests.lines(log, in: logs).filter { $0.contains("\traw\t") }
        #expect(raw.count == 1 && raw.first?.contains("changed") == true, "raw lines: \(raw)")
        await studio.settle()
    }

    /// C19 (3): a save that fails during the read. The clip stays, but the turn sees a revision
    /// that is not the saved one.
    @Test func aFailedSaveDuringABlockedReadKeepsTheCAF() async throws {
        let (package, _) = try await Self.oldTake()
        let (studio, hold, flushes) = try await Self.held(package, at: .block(2))
        defer { hold.gate.open() }
        let save = studio.environment.saveSession
        studio.environment.saveSession = { _, _ throws(SessionFileError) in
            throw .writeFailed(step: "test", errno: EIO)
        }

        try Self.edit(studio) { session throws(SessionError) in try session.renameTrack("t1", to: "Host") }
        await studio.serialized {}
        #expect(studio.saveError != nil)
        hold.gate.open()
        await studio.rawSweep

        #expect(Self.hasCAF(package) && flushes.calls == 0, "flushes: \(flushes.calls)")
        studio.environment.saveSession = save
        await studio.settle()
    }

    /// C19 (4): the turn of the job comes after the save of a clip delete and before the save of
    /// its Undo. The session in memory has the clip again, the disk does not, and a save waits.
    @Test func aTurnBetweenTwoSavesKeepsTheCAF() async throws {
        let (package, _) = try await Self.oldTake()
        let (studio, hold, flushes) = try await Self.held(package, at: .turn)
        defer { hold.gate.open() }
        let (save, saving) = (studio.environment.saveSession, AsyncGate())
        defer { saving.open() }
        studio.environment.saveSession = { session, lock throws(SessionFileError) in
            await saving.wait()
            return try await save(session, lock)
        }

        try Self.deleteClips(studio)
        await saving.entered()
        hold.gate.open()
        await until(limit: .seconds(10), "the job does not wait for its turn") { studio.writesWaiting == 1 }
        try studio.undo()
        saving.open()
        await studio.rawSweep
        await studio.serialized {}

        #expect(Self.hasCAF(package) && flushes.calls == 0, "flushes: \(flushes.calls)")
        #expect(try package.read().tracks.flatMap(\.clips).count == 1, "the Undo save has the clip")
        await studio.settle()
    }
}
