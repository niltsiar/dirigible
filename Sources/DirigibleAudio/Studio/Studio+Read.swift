import DirigibleCore
import Foundation
import os

/// The flags of one running agent read (decision 0062). A cancel of the caller sets `cancelled`;
/// a take start sets both.
final class ReadRun: Sendable {
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    let yielded = OSAllocatedUnfairLock(initialState: false)
}

extension Studio {
    /// Runs `read` for an agent read by time (decision 0062) on a utility GCD thread, with the
    /// session of now and the package that the lock holds now: an edit does not wait for its
    /// autosave, so the files can lag the window. It throws `.busy` during a take, a take start,
    /// a finalize, a level, a duck, an import, or `settle()`. A read holds no transport, so it
    /// never refuses a take: a take start ends it at its next block, and then it throws
    /// `.readYielded`. A cancel of the caller makes `isCancelled` true at the next block.
    /// `progress` gets the fraction on the main actor.
    public func readMix<Success: Sendable>(
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in },
        _ read:
            @escaping @Sendable (
                _ session: Session, _ package: URL, _ progress: @escaping @Sendable (Double) -> Void,
                _ isCancelled: @escaping @Sendable () -> Bool
            ) -> Success
    ) async throws(StudioError) -> Success {
        try checkIdle()
        let (session, lock, step, run) = (session, lock, environment.loudnessBlock, ReadRun())
        readRuns.append(run)
        defer { readRuns.removeAll { $0 === run } }
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
                                    return run.cancelled.withLock { $0 }
                                })
                        })
                }
            }
        } onCancel: {
            run.cancelled.withLock { $0 = true }
        }
        if run.yielded.withLock({ $0 }) { throw .readYielded }
        do { return try result.get() } catch { throw .file(error) }
    }

    /// Ends each running read of this studio at its next block, for a take start.
    func endReads() {
        for run in readRuns {
            run.yielded.withLock { $0 = true }
            run.cancelled.withLock { $0 = true }
        }
    }
}
