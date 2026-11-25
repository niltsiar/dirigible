import DirigibleCore
import Foundation
import os

/// The running archive or unarchive of a studio (decision 0072). `Studio.Transport` holds it, as
/// `ImportRun`. It is equal by the identity of its flags, so the transport stays Hashable.
public struct ArchiveRun: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case archive, unarchive }

    public let kind: Kind
    let flags: ArchiveFlags
    /// The job: its end is the end of the run.
    let task: Task<Result<ArchiveReport, StudioError>, Never>

    public static func == (a: Self, b: Self) -> Bool { a.flags === b.flags }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(flags)) }
}

/// The stop flags of a package job, which its conversion thread reads. Cancel and `settle()` stop
/// the job before its next file. A take start stops it at its next block, and the file in hand
/// keeps its form (decision 0019).
final class ArchiveFlags: Sendable {
    private struct State {
        var afterFile = false
        var now = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// True when the job starts no other file.
    var stopsAfterFile: Bool { state.withLock { $0.afterFile || $0.now } }
    /// True when the job ends the file in hand at its next block.
    var stopsNow: Bool { state.withLock { $0.now } }

    /// Sets the flag of `stop`. True only for the first stop, so the first stop names the cause.
    func stop(_ stop: ExportStop) -> Bool {
        state.withLock { state in
            defer { if stop == .take { state.now = true } else { state.afterFile = true } }
            return !state.afterFile && !state.now
        }
    }
}

extension Studio {
    /// True while the session has the archive attribute (`needsUnarchive`): from the first save of
    /// an archive to the last save of an unarchive, also in a mixed state after a stop.
    public var isArchived: Bool { needsUnarchive(session) }

    /// The running archive or unarchive, or nil.
    public var archiveRun: ArchiveRun? {
        if case .archiving(let run) = transport { run } else { nil }
    }

    /// The busy test of each job: a take, a placement, a level, a duck, a match, a silence scan, a
    /// sync, an import, a package job, a take start, or `settle()` runs.
    func checkNotBusy() throws(StudioError) {
        guard isIdle, !settling else { throw .busy }
    }

    /// Throws `.archived` on an archived studio: a play and an export read the FLAC files too slowly
    /// in place, so each unarchives first (decision 0072).
    func checkReadable() throws(StudioError) {
        guard !isArchived else { throw .archived }
    }

    /// Converts each pool WAV to FLAC with `archivePackage` (decision 0072). The job runs off the
    /// main actor in one turn of the write chain, and each other entry point throws `.busy` until
    /// its end. Both saves keep no backup. It throws `.busy` while this studio exports,
    /// transcribes, reads, or settles, and while a studio of `otherStudios` records, starts a take,
    /// or has a pending take; a pending take of this studio throws `.archive(.pendingTake)`. A play
    /// stops first. Cancel and `settle()` stop the job after the file in hand, and a take start in
    /// another studio at its next block: then it throws `.archive(.cancelled)`, `archiveStop` gives
    /// the cause, and the package keeps a valid mixed state that the next job ends. `progress` gets
    /// the fraction of the files on the main actor.
    public func archive(
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws(StudioError) -> ArchiveReport {
        try await runArchive(.archive, progress: progress)
    }

    /// Converts each FLAC back to a WAV with `unarchivePackage`, then saves the session with no
    /// attribute. The rules of `archive` apply; a pending take of this studio throws `.busy`.
    public func unarchive(
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws(StudioError) -> ArchiveReport {
        try await runArchive(.unarchive, progress: progress)
    }

    /// The Cancel of the progress sheet: the job stops after the file in hand.
    public func cancelArchive() { stopArchive(.user) }

    /// Sets the stop flag of the running job, with no wait: a take start never waits for a read
    /// of the job. The call that sets the flag first sets `archiveStop` and gives true.
    @discardableResult
    func stopArchive(_ stop: ExportStop) -> Bool {
        guard archiveRun?.flags.stop(stop) == true else { return false }
        archiveStop = stop
        return true
    }

    /// Stops the running job and waits for its end. `settle()` calls it with `.close`.
    func endArchive(_ stop: ExportStop) async {
        guard let run = archiveRun else { return }
        stopArchive(stop)
        _ = await run.task.value
    }

    /// The refusal of a package job by the state of now, or nil.
    private func archiveRefusal(_ kind: ArchiveRun.Kind) -> StudioError? {
        if session.recording != nil { return kind == .archive ? .archive(.pendingTake) : .busy }
        let takes = otherStudios().contains { $0.isStarting || $0.session.recording != nil }
        guard !settling, exportJob == nil, transcribing == nil, readRuns.isEmpty, !takes else { return .busy }
        return nil
    }

    private func runArchive(
        _ kind: ArchiveRun.Kind, progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws(StudioError) -> ArchiveReport {
        try checkNotBusy()
        if let refusal = archiveRefusal(kind) { throw refusal }
        let stopped = endPlayForTake()
        let flags = ArchiveFlags()
        (archiveProgress, archiveStop) = (0, nil)
        let task = Task { await archiveTurn(kind, flags, stopped, progress: progress) }
        transport = .archiving(ArchiveRun(kind: kind, flags: flags, task: task))
        defer { transport = .idle }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            _ = flags.stop(.user)
        }
        return try result.get()
    }

    /// The raw sweep wait, the refusals again, then the job in one turn of the write chain. The
    /// raw sweep removes no CAF while the transport is `.archiving` (decision 0071).
    private func archiveTurn(
        _ kind: ArchiveRun.Kind, _ flags: ArchiveFlags, _ stopped: Int?,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async -> Result<ArchiveReport, StudioError> {
        rawSweepJob.task?.cancel()
        if !rawSweepJob.waitsForTurn { await rawSweep }
        if let refusal = archiveRefusal(kind) { return .failure(refusal) }
        return await serialized { () async -> Result<ArchiveReport, StudioError> in
            _ = await takePlayhead(stopped, nil)  // The Player stops.
            if let refusal = archiveRefusal(kind) { return .failure(refusal) }
            // A main queue hop keeps the order of the fractions.
            let hop: @Sendable (Double) -> Void = { [weak self] fraction in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let self, self.archiveRun?.flags === flags {
                            self.archiveProgress = max(self.archiveProgress, fraction)
                        }
                        progress(fraction)
                    }
                }
            }
            let done = await convertPackage(
                kind, session, lock: lock, cache: peakLoad.cache, environment: environment, flags: flags,
                progress: hop)
            if let written = done.written {
                url = packageIdentity(written)
                // A change of only `archive` records no undo entry; the save wrote the whole session.
                var stored = session
                stored.archive = done.session.archive
                recordLevel(stored)
            }
            return done.result
        }
    }
}

/// One package job on a utility GCD thread, in the package that `lock` holds now (decision 0072).
/// Both saves write `session.xml` with no backup. `written` is the path of the last save.
@concurrent nonisolated func convertPackage(
    _ kind: ArchiveRun.Kind, _ session: Session, lock: PackageLock, cache: URL?, environment: CaptureEnvironment,
    flags: ArchiveFlags, progress: @escaping @Sendable (Double) -> Void
) async -> (result: Result<ArchiveReport, StudioError>, session: Session, written: URL?) {
    @Sendable func run() -> (result: Result<ArchiveReport, StudioError>, session: Session, written: URL?) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let package: URL
        do throws(SessionFileError) {
            package = try lock.package()
        } catch {
            return (.failure(.file(error)), session, nil)
        }
        let block: () -> Bool = {
            environment.archiveBlock()
            return flags.stopsNow
        }
        var seams = ArchiveSeams()
        seams.freeBytes = { _ in environment.freeBytes(lock) }
        seams.archive = { file, package, rate, _ throws(ClipArchiveFault) in
            try archiveClip(file, in: package, rate: rate, isCancelled: block)
        }
        seams.unarchive = { file, package, rate, _ throws(ClipArchiveFault) in
            try unarchiveClip(file, in: package, rate: rate, isCancelled: block)
        }
        var current = session
        var written: URL?
        let save = { (saved: Session) throws(SessionFileError) -> URL in
            let url = try saved.write(under: lock, backups: .none)
            written = url
            return url
        }
        do throws(ArchiveFault) {
            let report: ArchiveReport
            if kind == .archive {
                report = try archivePackage(
                    &current, in: package, cache: cache, progress: progress, isStopped: { flags.stopsAfterFile },
                    save: save, seams: seams)
            } else {
                report = try unarchivePackage(
                    &current, also: [], in: package, cache: cache, progress: progress,
                    isStopped: { flags.stopsAfterFile }, save: save, seams: seams)
            }
            return (.success(report), current, written)
        } catch {
            return (.failure(.archive(error)), current, written)
        }
    }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: run()) }
    }
}
