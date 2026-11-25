import DirigibleCore
import Foundation
import os

/// The raw sweep job of a studio (decision 0071), as `PeakLoad` is for the peak pass.
struct RawSweepJob {
    var task: Task<Void, Never>?
    /// `sweepRaw` during a run: the job runs once more.
    var again = false
    /// True while the job waits for its turn of the write chain, which a long turn (an import, a
    /// level) can hold.
    var waitsForTurn = false
}

extension Studio {
    /// The segments of CAFs with audio that no pool file points to (decision 0012). Derived from
    /// the session on each read, so an edit, an undo, or a redo changes it.
    public var unplacedSegments: [SegmentName] { DirigibleAudio.unplacedSegments(segmentsWithAudio, session: session) }
    /// False under a pending or split take (decision 0037): then a ripple must not move the
    /// timeline. A segment whose CAF opens but is not audio can never place, so it does not block.
    public var canRipple: Bool { canRipple(session) }

    /// Returns when no raw sweep job of this studio runs (decision 0071).
    public var rawSweep: Void {
        get async { while let task = rawSweepJob.task { await task.value } }
    }

    /// True while a take starts, records, or finalizes in this studio or in a studio of
    /// `otherStudios`, while this studio has a pending take, runs a package job (decision 0072), or
    /// settles: then the job removes no CAF and ends at its next step. A pending take of another
    /// studio records nothing.
    var rawSweepHeld: Bool {
        settling || isStarting || session.recording != nil || archiveRun != nil
            || otherStudios().contains { $0.isStarting || $0.session.recording != nil && $0.pendingTake == nil }
    }

    /// Starts the job after a take or a placement with no error, or marks the running job to run
    /// once more. With the hold set, or for a package that opened with no lock, it does nothing.
    func sweepRaw() {
        guard lock.isHeld, !rawSweepHeld else { return }
        guard rawSweepJob.task == nil else {
            rawSweepJob.again = true
            return
        }
        // The job holds the studio only for one step at a time, so a drop of the studio frees the
        // lock, as the peak pass does.
        rawSweepJob.task = Task { [weak self] in
            await Self.runRawSweep { [weak self] in self }
            self?.rawSweepJob.task = nil
        }
    }

    /// Stops the job of this studio and of each studio of `otherStudios`, and waits for each job
    /// that does not wait for its turn: such a job sees the hold at the start of its turn and ends.
    /// A take start calls it after it sets `isStarting` and before its `serialized` call: the job
    /// asks for a turn of its own chain, so a wait for it inside a turn does not end.
    func rawSweepsEnded() async {
        let studios = [self] + otherStudios()
        for studio in studios { studio.rawSweepJob.task?.cancel() }
        for studio in studios where !studio.rawSweepJob.waitsForTurn { await studio.rawSweep }
    }

    /// Cancels the job, so a read ends at its next segment or WAV block, and waits for it.
    func stopRawSweep() async {
        rawSweepJob.task?.cancel()
        await rawSweep
    }

    /// Waits while a take start of this studio runs up to its `begin`. A start waits for the sweep
    /// jobs before it takes its ticket, so `settle()` calls it before each `serialized` call: then the
    /// settle comes after the start in the chain and stops its take.
    func startsQueued() async {
        while isStarting { await withCheckedContinuation { startWaits.append($0) } }
    }

    func resumeStartWaits() {
        for waiter in startWaits { waiter.resume() }
        startWaits = []
    }

    /// Tests only: the calls that wait in `startsQueued()`.
    var startWaiters: Int { startWaits.count }

    /// The reads run on a utility thread; each removal runs in a turn of the write chain. The job
    /// tests the hold before its reads, after the WAV read of a take with no finalize record, right
    /// before it asks for a turn, and at the start of the turn. A studio that is gone ends it.
    private static func runRawSweep(_ studio: () -> Studio?) async {
        guard let environment = studio()?.environment else { return }
        let (step, readStep) = (environment.beforeRawStep, environment.rawReadStep)
        repeat {
            studio()?.rawSweepJob.again = false
            guard studio()?.rawSweepHeld == false else { return }
            await step(.first)
            // Each read holds the lock only for its own run.
            let candidates: [(name: SegmentName, files: [FileIdentity?], record: FinalizeRecord?)]
            do {
                guard let current = studio(), !current.rawSweepHeld else { return }
                let (session, lock) = (current.session, current.lock)
                candidates = await utilityRead {
                    readRemovable(of: session, lock: lock, isCancelled: $0, step: readStep)
                }
            }
            for candidate in candidates {
                var read = candidate.record.map { RawRead(files: candidate.files, record: $0) }
                if read == nil, let lock = studio()?.lock {
                    let name = candidate.name
                    switch await utilityRead({ readOldTake(name, lock: lock, isCancelled: $0, step: readStep) }) {
                    case .success(let old?):
                        read = RawRead(
                            files: candidate.files, record: old.record, appends: !old.saturated,
                            saturated: old.saturated)
                    case .success(nil): break
                    case .failure(let error): studio()?.environment.log.noteRawFault(candidate.name, error)
                    }
                }
                guard studio()?.rawSweepHeld == false, !Task.isCancelled else { return }
                guard let read else { continue }
                await step(.turn)
                guard let current = studio(), !current.rawSweepHeld else { return }
                current.rawSweepJob.waitsForTurn = true
                await current.serialized {
                    current.rawSweepJob.waitsForTurn = false
                    await current.removeInTurn(candidate.name, read: read)
                }
            }
        } while studio()?.rawSweepJob.again == true
    }

    /// With no waiting save and the saved revision, `session` is the session on the disk. Else the
    /// CAF stays for the next sweep. An edit during the removal changes only memory: its save waits
    /// for the end of this turn.
    private func removeInTurn(_ name: SegmentName, read: RawRead) async {
        guard !rawSweepHeld, !saveWaits, sessionRevision == savedRevision else { return }
        guard let error = await removeRaw(name, of: session, lock: lock, read: read, flush: environment.rawFlush)
        else { return }
        environment.log.noteRawFault(name, error)
    }
}

/// `work` on a utility GCD thread, as an export (decision 0019): a Swift task that a caller
/// awaits takes the priority of that caller. On that thread `Task.isCancelled` is false, so a
/// cancel of the job sets the flag that `work` reads.
@concurrent nonisolated private func utilityRead<Value: Sendable>(
    _ work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) -> Value
) async -> Value {
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work { cancelled.withLock { $0 } })
            }
        }
    } onCancel: {
        cancelled.withLock { $0 = true }
    }
}

/// `removableCaptures` in the package that `lock` holds now, with the step `.segment(n)` before
/// each segment. `isCancelled` ends the read.
private func readRemovable(
    of session: Session, lock: PackageLock, isCancelled: () -> Bool, step: (RawSweepStep) -> Void
) -> [(name: SegmentName, files: [FileIdentity?], record: FinalizeRecord?)] {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let package = try? lock.package() else { return [] }
    return removableCaptures(
        of: session, in: package, isCancelled: isCancelled, beforeSegment: { step(.segment($0)) })
}

/// `oldTakeRecord` in the package that `lock` holds now, with the step `.block(n)` before each
/// WAV block. `isCancelled` ends the read.
private func readOldTake(
    _ name: SegmentName, lock: PackageLock, isCancelled: @escaping @Sendable () -> Bool,
    step: (RawSweepStep) -> Void
) -> Result<(record: FinalizeRecord, saturated: Bool)?, RawRemovalError> {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let package = try? lock.package() else { return .success(nil) }
    do throws(RawRemovalError) {
        return .success(try oldTakeRecord(of: name, in: package, isCancelled: isCancelled) { step(.block($0)) })
    } catch {
        return .failure(error)
    }
}

/// `removeRawCapture` in the package that `lock` holds now. Returns the fault.
@concurrent nonisolated private func removeRaw(
    _ name: SegmentName, of session: Session, lock: PackageLock, read: RawRead,
    flush: @Sendable (String) -> Int32?
) async -> RawRemovalError? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let package = try? lock.package() else { return nil }
    do throws(RawRemovalError) {
        _ = try removeRawCapture(name, of: session, in: package, read: read, flush: flush)
        return nil
    } catch {
        return error
    }
}
