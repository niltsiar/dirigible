import DirigibleCore
import Foundation
import os

/// The export that a Studio runs (decision 0019). One stored value, as `play` and `peakLoad`.
struct ExportJob {
    /// One more for each export, so a late progress hop of an ended export changes nothing.
    let number: Int
    /// The target, or the first target of a set: the disk check of a take in another studio ends
    /// only an export to its volume.
    let url: URL
    var progress: Double
    /// The part in hand of a set.
    var file: ExportPartsProgress?
    /// The progress of the caller of `export`.
    let report: @MainActor @Sendable (Double) -> Void
    /// A cancel of it reaches the cancel flag of the GCD job; its end is the end of the job.
    let task: Task<Void, Never>
    /// A Save as Template copy (decision 0079): Remove Unused Files waits for its end.
    var isTemplate = false
    /// The presets of a preset set, in file order (decision 0080).
    var presets: [PresetRef]?
}

/// The cause of an export or an import end before its end: Cancel in the export sheet or the
/// import banner, a take start, or the close of the window (`settle()`).
public enum ExportStop: Sendable {
    case user, take, close
}

extension Studio {
    /// The fraction of the running export, in 0...1. Nil when no export runs.
    public var exportProgress: Double? { exportJob?.progress }

    /// The number, the count, and the name of the file in hand of a running split export.
    public var exportFile: ExportPartsProgress? { exportJob?.file }

    /// True while the job in the export slot is a Save as Template copy (decision 0079).
    public var savesTemplate: Bool { exportJob?.isTemplate == true }

    /// The faults of the files that `source` reads, off the main actor: the media question
    /// before an export (decision 0003). Nil when the check cannot run: the package left its
    /// volume, or the process has no free descriptor.
    public func exportFaults(_ source: ExportSource) async -> [FileID: MediaFault]? {
        await mediaFaults(session, lock: lock, source: source, before: environment.beforeMediaCheck)
    }

    /// Exports `source` of the session of now to `url` (decision 0019). An edit during the export
    /// is saved and does not change the file. It throws `.busy` during a take start, a take, a
    /// finalize, a pending take, another export, or a `settle()`. A take start and `settle()`
    /// cancel it: then it throws `.export(.cancelled)`, and `exportStop` gives the cause. A cancel
    /// of the caller cancels it too (decision 0049). `progress` gets the fraction on the main actor.
    /// Returns the report: the faults of the files that the export read, and the loudness with a
    /// target.
    public func export(
        _ source: ExportSource, _ options: ExportOptions, to url: URL, replacing: ConfirmedFile?,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws(StudioError) -> ExportResult {
        try checkNotBusy()
        try checkReadable()
        guard pendingTake == nil, exportJob == nil, !settling else { throw .busy }
        exportNumber += 1
        exportStop = nil
        let number = exportNumber
        let session = session
        let hop: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.exportProgressed(number, fraction) }
        }
        let task = jobTask { package, isCancelled in
            Result { () throws(ExportError) in
                try exportMix(
                    session, source: source, options: options, to: url, replacing: replacing, package: package,
                    progress: hop, isCancelled: isCancelled)
            }
        }
        exportJob = ExportJob(number: number, url: url, progress: 0, report: progress, task: Self.handle(task))
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if exportJob?.number == number { exportJob = nil }
        if case .failure(.cancelled) = result, yieldedExport == number { throw .exportYielded }
        do { return try result.get() } catch { throw .export(error) }
    }

    /// Cancels the running export: Cancel in the export sheet. It ends within one chunk.
    public func cancelExport() {
        guard let job = exportJob else { return }
        exportStop = .user
        job.task.cancel()
    }

    /// Cancels the running export and waits for its end. `settle()` calls it after it sets
    /// `settling`. A take start calls it after its lookup, route, and access checks and before
    /// its disk check and its save, so a refused take start keeps the export. With `yielding`,
    /// a take of another studio ends it, and `export` throws `.exportYielded`. `exportStop` gets
    /// `stop`.
    func endExport(_ stop: ExportStop, yielding: Bool = false) async {
        guard let job = exportJob else { return }
        exportStop = stop
        if yielding { yieldedExport = job.number }
        job.task.cancel()
        _ = await job.task.value
        if exportJob?.number == job.number { exportJob = nil }
    }

    /// `endExport` and `endReads` of this studio, `endExport`, `endImport`, `stopArchive`, and
    /// `endReads` of each other studio, and the end of each job of `copyJobs`, for a take start
    /// (`prepareTake`, off the main actor): capture comes first across windows (decisions 0019,
    /// 0040, 0062, 0072, and 0079). Nil when no export, import, package job, read, or copy runs:
    /// then the start needs no main-actor turn for it. An export, an import, a read, or a copy that
    /// starts during the take start runs on; the disk check of the take watches the export, the
    /// import, the package job, and the copy.
    func exportEnd() -> (@MainActor @Sendable () async -> Void)? {
        let others = otherStudios().filter {
            $0.exportJob != nil || $0.importRun != nil || $0.archiveRun != nil || !$0.readRuns.isEmpty
        }
        let copies = copyJobs?.jobs ?? []
        guard exportJob != nil || !readRuns.isEmpty || !others.isEmpty || !copies.isEmpty else { return nil }
        return { [weak self] in
            self?.endReads(.take)
            await self?.endExport(.take)
            for studio in others {
                studio.endReads(.take)
                await studio.endExport(.take, yielding: true)
                studio.endImport(.take)
                studio.stopArchive(.take)
            }
            for job in copies { await job.end() }
        }
    }

    /// Ends the exports of the other studios and the jobs of `copyJobs` to the volume of the
    /// package, and the imports of the other studios whose package is on it, for the disk check of
    /// a take. True when an export or a copy ran or when this call set the flag of an import. An
    /// import whose flag is already set (by Cancel, `settle()`, or another take) does not count,
    /// so a stalled import read cannot keep the take from its disk-low stop at the next check (code
    /// gate 2). The volume reads run off the main actor.
    func endOtherExports(onVolumeOf lock: PackageLock) async -> Bool {
        var ended = false
        for job in copyJobs?.jobs ?? [] {
            if await onVolume(job.url.deletingLastPathComponent(), of: lock) {
                await job.end()
                ended = true
            }
        }
        for studio in otherStudios() {
            if let job = studio.exportJob, await onVolume(job.url.deletingLastPathComponent(), of: lock) {
                await studio.endExport(.take, yielding: true)
                ended = true
            }
            if studio.importRun != nil, await onVolume(studio.url, of: lock) {
                if studio.endImport(.take) { ended = true }
            }
            if studio.archiveRun != nil, await onVolume(studio.url, of: lock) {
                if studio.stopArchive(.take) { ended = true }
            }
        }
        return ended
    }

    /// The progress hop of export `number`. A hop of another export changes nothing.
    func exportProgressed(_ number: Int, _ fraction: Double) {
        guard let job = exportJob, job.number == number else { return }
        exportJob?.progress = fraction
        job.report(fraction)
    }

    /// The progress hop of split export `number`. A hop of another export changes nothing.
    func exportPartProgressed(_ number: Int, _ file: ExportPartsProgress) {
        guard let job = exportJob, job.number == number else { return }
        exportJob?.progress = file.fraction
        exportJob?.file = file
        job.report(file.fraction)
    }

    /// The job: `work` (`exportMix` or `exportParts`) on a utility GCD thread. A Swift task that a
    /// caller awaits takes the priority of that caller, so the chunk loop does not run in one (plan
    /// gate 1). On a GCD thread `Task.isCancelled` is false, so a cancel of the job sets a flag that
    /// the loop reads.
    func jobTask<Value: Sendable>(
        _ work: @escaping @Sendable (_ package: () throws(SessionFileError) -> URL, _ isCancelled: () -> Bool) -> Value
    ) -> Task<Value, Never> {
        let (lock, step) = (lock, environment.exportChunk)
        return Self.utilityTask { isCancelled in
            work(
                { () throws(SessionFileError) -> URL in try lock.package() },
                {
                    step()
                    return isCancelled()
                })
        }
    }

    /// `work` on a utility GCD thread, with the cancel flag that a cancel of the task sets: the
    /// thread of `jobTask` and of the template copy of `create`.
    static func utilityTask<Value: Sendable>(
        _ work: @escaping @Sendable (_ isCancelled: () -> Bool) -> Value
    ) -> Task<Value, Never> {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return Task {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(returning: work { cancelled.withLock { $0 } })
                    }
                }
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
        }
    }

    /// The `ExportJob.task` of `task`: its cancel cancels `task`, so it reaches the flag of the job.
    static func handle<Value: Sendable>(_ task: Task<Value, Never>) -> Task<Void, Never> {
        Task {
            await withTaskCancellationHandler {
                _ = await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }
}

extension Studio {
    /// Exports one file for each part of `source` of the session of now, split at `kind`, to
    /// `folder` with the names of `exportPartTargets` (decision 0067). It is one export job: it
    /// throws `.busy` as `export`, and a take start in this or another studio, `settle()`, Cancel,
    /// and a cancel of the caller stop the whole set with `.exportParts(.stopped(_))`; `exportStop`
    /// gives the cause. The job computes the parts and the targets on the session that it renders,
    /// so an edit after the caller listed the targets refuses an unconfirmed name. With no split
    /// point it throws `.exportParts(.noPoint(_, _))` and starts no job. `exportFile` gives the part
    /// in hand.
    public func export(
        _ source: ExportSource, by kind: SplitKind, options: ExportOptions, folder: URL, prefix: String,
        replacing: [URL: ConfirmedFile],
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws(StudioError) -> ExportPartsResult {
        try checkNotBusy()
        try checkReadable()
        guard pendingTake == nil, exportJob == nil, !settling else { throw .busy }
        let session = session
        let targets = exportPartTargets(
            session, range: source.range, by: kind, options: options, folder: folder, prefix: prefix)
        guard let first = targets.targets.first else { throw .exportParts(.noPoint(kind, source.range)) }
        exportNumber += 1
        exportStop = nil
        let number = exportNumber
        let hop: @Sendable (ExportPartsProgress) -> Void = { [weak self] file in
            Task { @MainActor in self?.exportPartProgressed(number, file) }
        }
        let task = jobTask { package, isCancelled in
            Result { () throws(ExportPartsError) in
                try exportParts(
                    session, source: source, by: kind, options: options, folder: folder, prefix: prefix,
                    replacing: replacing, package: package, progress: hop, isCancelled: isCancelled)
            }
        }
        exportJob = ExportJob(number: number, url: first.url, progress: 0, report: progress, task: Self.handle(task))
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if exportJob?.number == number { exportJob = nil }
        do { return try result.get() } catch { throw .exportParts(error) }
    }

    /// Exports one file for each stem of `source` of the session of now into the new folder `folder`
    /// (`exportStems`). It is one export job: it throws `.busy` as `export`, and a take start in this
    /// or another studio, `settle()`, Cancel, and a cancel of the caller stop it with
    /// `.exportStems(.stopped(.cancelled))` and no folder; `exportStop` gives the cause. The job URL
    /// is `folder`, so the disk check of a take reads the volume of its parent. A folder name over
    /// `stemFolderNameLimit` throws `.exportStems(.folderNameTooLong)` and starts no job.
    public func exportStems(
        by grouping: StemGrouping, source: ExportSource, titles: StemTitles, options: StemOptions, folder: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws(StudioError) -> StemsResult {
        try checkNotBusy()
        try checkReadable()
        guard pendingTake == nil, exportJob == nil, !settling else { throw .busy }
        guard folder.lastPathComponent.utf8.count <= stemFolderNameLimit else {
            throw .exportStems(.folderNameTooLong)
        }
        exportNumber += 1
        exportStop = nil
        let number = exportNumber
        let session = session
        let hop: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.exportProgressed(number, fraction) }
        }
        let task = jobTask { package, isCancelled in
            Result { () throws(ExportStemsError) in
                try DirigibleAudio.exportStems(
                    session, by: grouping, source: source, titles: titles, options: options, to: folder,
                    package: package, progress: hop, isCancelled: isCancelled)
            }
        }
        exportJob = ExportJob(number: number, url: folder, progress: 0, report: progress, task: Self.handle(task))
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if exportJob?.number == number { exportJob = nil }
        do { return try result.get() } catch { throw .exportStems(error) }
    }
}

extension Studio {
    /// `writeChapters` of `range` of `session` to `url` in `form` on a utility GCD thread, in the
    /// package that the lock holds now. Pass `replacingImages` true when the save panel confirmed
    /// the replace of an item at `url`: the chapter images beside it are replaced too. Else an item
    /// at the name of an image stops the write.
    public func exportChapters(
        _ session: Session, in range: Range<Frames>, to url: URL, form: ChaptersForm, replacingImages: Bool
    ) async throws(ExportError) {
        let lock = lock
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: Result { () throws(ExportError) in
                        let package: URL
                        do { package = try lock.package() } catch { throw .packageUnavailable }
                        try writeChapters(
                            session, in: range, to: url, form: form, replacingImages: replacingImages,
                            package: package)
                    })
            }
        }
        try result.get()
    }

    /// The SRT or WebVTT file of transcript `number` of `session` (decision 0061), the text of
    /// `dirigible transcript export`, written atomically to `url` off the main actor. The caller
    /// confirmed the replace of an item at `url`. It returns the count of units left out because
    /// their range has no length.
    @concurrent public nonisolated func exportTranscript(
        _ session: Session, transcript number: Int, as format: SubtitleFormat, to url: URL
    ) async throws(TranscriptExportError) -> Int {
        let file: (text: String, left: Int)
        do { file = try session.subtitleFile(ofTranscript: number, as: format) } catch { throw .cues(error) }
        do { try Data(file.text.utf8).write(to: url, options: .atomic) } catch {
            throw .write(ExportError(writing: error))
        }
        return file.left
    }
}

/// Why `Studio.exportTranscript` wrote no file.
public enum TranscriptExportError: Error, Hashable, Sendable {
    /// The transcript gives no cue.
    case cues(SubtitleError)
    /// The atomic write failed: the old file, or no file, stays.
    case write(ExportError)
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
