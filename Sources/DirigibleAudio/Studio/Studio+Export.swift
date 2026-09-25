import DirigibleCore
import Foundation
import os

/// The export that a Studio runs (decision 0019). One stored value, as `play` and `peakLoad`.
struct ExportJob {
    /// One more for each export, so a late progress hop of an ended export changes nothing.
    let number: Int
    /// The target: the disk check of a take in another studio ends only an export to its volume.
    let url: URL
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
        exportJob = ExportJob(number: number, url: url, progress: 0, task: task)
        let result = await task.value
        if exportJob?.number == number { exportJob = nil }
        if case .failure(.cancelled) = result, yieldedExport == number { throw .exportYielded }
        do { return try result.get() } catch { throw .export(error) }
    }

    /// Cancels the running export. It ends within one chunk.
    public func cancelExport() {
        exportJob?.task.cancel()
    }

    /// Cancels the running export and waits for its end. `settle()` calls it after it sets
    /// `settling`. A take start calls it after its lookup, route, and access checks and before
    /// its disk check and its save, so a refused take start keeps the export. With `yielding`,
    /// a take of another studio ends it, and `export` throws `.exportYielded`.
    func endExport(yielding: Bool = false) async {
        guard let job = exportJob else { return }
        if yielding { yieldedExport = job.number }
        job.task.cancel()
        _ = await job.task.value
        if exportJob?.number == job.number { exportJob = nil }
    }

    /// `endExport` of this studio and of each other studio for a take start (`prepareTake`, off
    /// the main actor): capture comes first across windows (decision 0019). Nil when no export
    /// runs: then the start needs no main-actor turn for it. An export of another studio that
    /// starts during the take start runs on; the disk check of the take watches it.
    func exportEnd() -> (@MainActor @Sendable () async -> Void)? {
        let others = otherStudios().filter { $0.exportJob != nil }
        guard exportJob != nil || !others.isEmpty else { return nil }
        return { [weak self] in
            await self?.endExport()
            for studio in others { await studio.endExport(yielding: true) }
        }
    }

    /// Ends the exports of the other studios to the volume of the package, for the disk check
    /// of a take. True when one ran. The volume reads run off the main actor.
    func endOtherExports(onVolumeOf lock: PackageLock) async -> Bool {
        var ended = false
        for studio in otherStudios() {
            guard let job = studio.exportJob, await onVolume(job.url.deletingLastPathComponent(), of: lock) else {
                continue
            }
            await studio.endExport(yielding: true)
            ended = true
        }
        return ended
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

/// True when `folder` is on the volume of the package that `lock` holds now.
@concurrent nonisolated func onVolume(_ folder: URL, of lock: PackageLock) async -> Bool {
    guard let package = try? lock.package() else { return false }
    return sameVolume(folder, package)
}

/// True when both items exist and `stat` gives both the same device.
nonisolated func sameVolume(_ a: URL, _ b: URL) -> Bool {
    var (first, second) = (stat(), stat())
    return stat(a.path, &first) == 0 && stat(b.path, &second) == 0 && first.st_dev == second.st_dev
}
