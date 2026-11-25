import DirigibleCore
import Foundation
import os

/// The flags of one running agent read (decision 0062). A cancel of the caller sets `cancelled`;
/// a take start or the close of the window sets `end`, the first cause, and then `cancelled`. The
/// read sets `observed` when it sees `cancelled` at a block, so a read that completed before the
/// end keeps its result. A transcription job (decision 0065 D5) is a read run too: `stop` is the
/// flag that the abort callback of whisper.cpp reads, and each stop source sets it with `cancelled`.
/// A read of a model file (decision 0065 D8) is not `joined`: its `open` or `pread` can block in the
/// kernel (a share that stops answering, a dataless iCloud file), where no stop reaches it, and it
/// reads no package file.
final class ReadRun: Sendable {
    /// Why the app ended the read: a take start, or the close of the window (`settle()`).
    enum End: Sendable { case take, close }

    let cancelled = OSAllocatedUnfairLock(initialState: false)
    let end = OSAllocatedUnfairLock<End?>(initialState: nil)
    let observed = OSAllocatedUnfairLock(initialState: false)
    let stop = StopFlag()
    /// True when `settle()` waits for the end of this run.
    let joined: Bool

    init(joined: Bool = true) { self.joined = joined }

    /// Sets `cancelled` and `stop`: a cancel of the caller or of the banner.
    func cancel() {
        cancelled.withLock { $0 = true }
        stop.set()
    }
}

extension Studio {
    /// Runs `read` for an agent read by time (decision 0062) on a utility GCD thread, with the
    /// session of now and the package that the lock holds now: an edit does not wait for its
    /// autosave, so the files can lag the window. It throws `.busy` during a take, a take start,
    /// a finalize, a level, a duck, an import, or `settle()`. A read holds no transport, so it
    /// never refuses a take: a take start ends it at its next block, and then it throws
    /// `.readYielded`; `settle()` ends it too, and then it throws `.readClosed`. A read that saw no
    /// stop returns its result, also after a late take start.
    /// A cancel of the caller makes `isCancelled` true at the next block.
    /// `progress` gets the fraction on the main actor.
    public func readMix<Success: Sendable>(
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in },
        _ read:
            @escaping @Sendable (
                _ session: Session, _ package: URL, _ progress: @escaping @Sendable (Double) -> Void,
                _ isCancelled: @escaping @Sendable () -> Bool
            ) -> Success
    ) async throws(StudioError) -> Success {
        try checkNotBusy()
        try checkReadable(.export)
        let (session, lock, step, run) = (session, lock, environment.loudnessBlock, ReadRun())
        readRuns.append(run)
        defer { endRead(run) }
        let hop: @Sendable (Double) -> Void = { fraction in Task { @MainActor in progress(fraction) } }
        // On a GCD thread `Task.isCancelled` is false, so a cancel of the caller sets a flag that
        // the read reads at each block, as `measureLoudness`.
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(
                        returning: Result { () throws(SessionFileError) in
                            read(
                                session, try lock.package(), hop,
                                {
                                    step()
                                    let stop = run.cancelled.withLock { $0 }
                                    if stop { run.observed.withLock { $0 = true } }
                                    return stop
                                })
                        })
                }
            }
        } onCancel: {
            run.cancelled.withLock { $0 = true }
        }
        if run.observed.withLock({ $0 }), let end = run.end.withLock({ $0 }) {
            throw end == .take ? .readYielded : .readClosed
        }
        do { return try result.get() } catch { throw .file(error) }
    }

    /// Ends each running read of this studio at its next block, for a take start or `settle()`.
    func endReads(_ end: ReadRun.End) {
        for run in readRuns {
            run.end.withLock { $0 = $0 ?? end }
            run.cancel()
        }
    }

    /// Takes `run` out of `readRuns`. After the last joined run, the waits of `readsEnded()` resume.
    func endRead(_ run: ReadRun) {
        readRuns.removeAll { $0 === run }
        if !readRuns.contains(where: \.joined) {
            for waiter in readWaiters { waiter.resume() }
            readWaiters = []
        }
    }

    /// Waits for the end of each running joined read. `settle()` calls it after `endReads(.close)`; a
    /// read of a model file runs on and finds its stop set.
    func readsEnded() async {
        guard readRuns.contains(where: \.joined) else { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }
}
