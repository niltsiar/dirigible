import DirigibleCore
import Foundation

/// The raw sweep job of a studio (decision 0071), as `PeakLoad` is for the peak pass.
struct RawSweepJob {
    var task: Task<Void, Never>?
    /// `sweepRaw` during a run: the job runs once more.
    var again = false
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

    /// True while a take starts or records in this studio or in a studio of `otherStudios`, or
    /// while this studio settles: then the job removes no CAF and ends at its next step.
    var rawSweepHeld: Bool {
        settling || ([self] + otherStudios()).contains { $0.isStarting || $0.session.recording != nil }
    }

    /// Starts the job after a take or a placement with no error, or marks the running job to run
    /// once more. With the hold set, it does nothing.
    func sweepRaw() {
        guard !rawSweepHeld else { return }
        guard rawSweepJob.task == nil else {
            rawSweepJob.again = true
            return
        }
        rawSweepJob.task = Task {
            await runRawSweep()
            rawSweepJob.task = nil
        }
    }

    /// Stops the job of this studio and of each studio of `otherStudios`, and waits for each. A
    /// take start calls it after it sets `isStarting` and before its `serialized` call: the job
    /// asks for a turn of its own chain, so a wait for it inside a turn does not end.
    func rawSweepsEnded() async { await stopRawSweeps([self] + otherStudios()) }

    /// Cancels the job of each studio of `studios`, so a WAV read ends at its next block, and waits
    /// for each.
    func stopRawSweeps(_ studios: [Studio]) async {
        for studio in studios { studio.rawSweepJob.task?.cancel() }
        for studio in studios { await studio.rawSweep }
    }

    /// Waits while a take start of this studio runs up to its `begin`. A start waits for the sweep
    /// jobs before it takes its ticket, so `settle()` calls it before each `serialized` call: then the
    /// settle comes after the start in the chain and stops its take.
    func startsQueued() async {
        while isStarting { await Task { try? await Task.sleep(for: .milliseconds(10)) }.value }
    }

    /// The reads run off the main actor; each removal runs in a turn of the write chain. The job
    /// tests the hold before its reads, after the WAV read of a take with no finalize record, right
    /// before it asks for a turn, and at the start of the turn.
    private func runRawSweep() async {
        let step = environment.beforeRawStep
        repeat {
            rawSweepJob.again = false
            guard !rawSweepHeld else { return }
            await step(.first)
            guard !rawSweepHeld else { return }
            for candidate in await readRemovable(of: session, lock: lock) {
                var read = candidate.record.map { RawRead(files: candidate.files, record: $0) }
                if read == nil {
                    switch await readOldTake(candidate.name, lock: lock, step: step) {
                    case .success(let record?): read = RawRead(files: candidate.files, record: record, appends: true)
                    case .success(nil): break
                    case .failure(let error): noteRawFault(candidate.name, error)
                    }
                }
                guard !rawSweepHeld, !Task.isCancelled else { return }
                guard let read else { continue }
                await step(.turn)
                guard !rawSweepHeld else { return }
                await serialized { await removeInTurn(candidate.name, read: read) }
            }
        } while rawSweepJob.again
    }

    /// With no waiting save and the saved revision, `session` is the session on the disk. Else the
    /// CAF stays for the next sweep. An edit during the removal changes only memory: its save waits
    /// for the end of this turn.
    private func removeInTurn(_ name: SegmentName, read: RawRead) async {
        guard !rawSweepHeld, !saveWaits, sessionRevision == savedRevision else { return }
        guard let error = await removeRaw(name, of: session, lock: lock, read: read, flush: environment.rawFlush)
        else { return }
        noteRawFault(name, error)
    }

    /// One `raw` line of the journal (decision 0059).
    private func noteRawFault(_ name: SegmentName, _ error: RawRemovalError) {
        let (fault, code) = error.journal
        environment.log.note(
            .raw, "fault", level: .error,
            ["segment": .text(name.stem), "error": .text(fault), "errno": .number(Int64(code))])
    }
}

@concurrent nonisolated private func readRemovable(of session: Session, lock: PackageLock) async -> [(
    name: SegmentName, files: [FileIdentity?], record: FinalizeRecord?
)] {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let package = try? lock.package() else { return [] }
    return removableCaptures(of: session, in: package)
}

/// `oldTakeRecord` in the package that `lock` holds now, with the step `.block(n)` before each
/// WAV block. A cancel of the job ends the read.
@concurrent nonisolated private func readOldTake(
    _ name: SegmentName, lock: PackageLock, step: @escaping @Sendable (RawSweepStep) async -> Void
) async -> Result<FinalizeRecord?, RawRemovalError> {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let package = try? lock.package() else { return .success(nil) }
    do throws(RawRemovalError) {
        return .success(
            try await oldTakeRecord(of: name, in: package, isCancelled: { Task.isCancelled }) { await step(.block($0)) }
        )
    } catch {
        return .failure(error)
    }
}

/// `removeRawCapture` in the package that `lock` holds now. Returns the fault.
@concurrent nonisolated private func removeRaw(
    _ name: SegmentName, of session: Session, lock: PackageLock, read: RawRead,
    flush: @escaping @Sendable (String) -> Int32?
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
