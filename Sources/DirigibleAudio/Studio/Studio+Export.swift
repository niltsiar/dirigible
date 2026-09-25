import DirigibleCore
import Foundation
import os

/// The export that a Studio runs (decision 0019). One stored value, as `play` and `peakLoad`.
struct ExportJob {
    /// One more for each export, so a late progress hop of an ended export changes nothing.
    let number: Int
    var progress: Double
    let task: Task<Result<[FileID: MediaFault], ExportError>, Never>
}

extension Studio {
    /// The fraction of the running export, in 0...1. Nil when no export runs.
    public var exportProgress: Double? { exportJob?.progress }

    /// The faults of the files that `source` reads, off the main actor: the media question
    /// before an export (decision 0003). Nil when the check cannot run: the package left its
    /// volume, or the process has no free descriptor.
    public func exportFaults(_ source: ExportSource) async -> [FileID: MediaFault]? {
        await mediaFaults(session, lock: lock, source: source)
    }

    /// Exports `source` of the session of now to `url` (decision 0019). An edit during the export
    /// is saved and does not change the file. It throws `.busy` during a take start, a take, a
    /// finalize, a pending take, another export, or a `settle()`. A take start and `settle()`
    /// cancel it: then it throws `.export(.cancelled)`. Returns the faults of the files that the
    /// export read: the report.
    public func export(
        _ source: ExportSource, _ options: ExportOptions, to url: URL, replacing: ConfirmedFile?
    ) async throws(StudioError) -> [FileID: MediaFault] {
        try checkIdle()
        guard pendingTake == nil, exportJob == nil, !settling else { throw .busy }
        exportNumber += 1
        let number = exportNumber
        let task = exportTask(number, session, source, options, url, replacing)
        exportJob = ExportJob(number: number, progress: 0, task: task)
        let result = await task.value
        if exportJob?.number == number { exportJob = nil }
        do { return try result.get() } catch { throw .export(error) }
    }

    /// Cancels the running export. It ends within one chunk.
    public func cancelExport() {
        exportJob?.task.cancel()
    }

    /// Cancels the running export and waits for its end. `settle()` calls it after it sets
    /// `settling`. A take start calls it after its lookup, route, and access checks and before
    /// its disk check and its save, so a refused take start keeps the export.
    func endExport() async {
        guard let job = exportJob else { return }
        job.task.cancel()
        _ = await job.task.value
        if exportJob?.number == job.number { exportJob = nil }
    }

    /// `endExport` for `prepareTake`, off the main actor. Nil when no export runs: no export
    /// starts while a take starts, so the start then needs no main-actor turn for it.
    func exportEnd() -> (@MainActor @Sendable () async -> Void)? {
        guard exportJob != nil else { return nil }
        return { [weak self] in await self?.endExport() }
    }

    /// The progress hop of export `number`. A hop of another export changes nothing.
    func exportProgressed(_ number: Int, _ fraction: Double) {
        guard exportJob?.number == number else { return }
        exportJob?.progress = fraction
    }

    /// The job: `exportMix` on a utility GCD thread. A Swift task that a caller awaits takes the
    /// priority of that caller, so the chunk loop does not run in one (plan gate 1). On a GCD
    /// thread `Task.isCancelled` is false, so a cancel of the job sets a flag that the loop reads.
    private func exportTask(
        _ number: Int, _ session: Session, _ source: ExportSource, _ options: ExportOptions, _ url: URL,
        _ replacing: ConfirmedFile?
    ) -> Task<Result<[FileID: MediaFault], ExportError>, Never> {
        let (lock, step) = (lock, environment.exportChunk)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let hop: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.exportProgressed(number, fraction) }
        }
        return Task {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        let result = Result { () throws(ExportError) in
                            try exportMix(
                                session, source: source, options: options, to: url, replacing: replacing,
                                package: { () throws(SessionFileError) -> URL in try lock.package() },
                                progress: hop,
                                isCancelled: {
                                    step()
                                    return cancelled.withLock { $0 }
                                })
                        }
                        continuation.resume(returning: result)
                    }
                }
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
        }
    }
}
