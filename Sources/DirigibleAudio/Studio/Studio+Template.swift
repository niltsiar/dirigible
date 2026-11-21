import DirigibleCore
import Foundation

/// The copies of `Studio.create` with a template (decision 0079). A copy runs before its studio
/// exists, so `otherStudios` does not see it: a take start in a studio that holds this list ends
/// each copy, and the disk check of a take ends each copy into a folder on its volume. The app
/// holds one list, and gives it to `create` and to the studio of each window.
@MainActor public final class CopyJobs {
    @MainActor final class Job {
        let number: Int
        /// The new package.
        let url: URL
        /// A cancel of it sets the cancel flag of the copy; its end is the end of the copy.
        let task: Task<Void, Never>
        /// True after `end()`: a take, not the caller, stopped the copy.
        private(set) var yielded = false

        init(number: Int, url: URL, task: Task<Void, Never>) {
            (self.number, self.url, self.task) = (number, url, task)
        }

        /// The end for a take start or the take disk check: sets the cancel flag and waits for the
        /// end of the copy.
        func end() async {
            yielded = true
            task.cancel()
            await task.value
        }
    }

    private(set) var jobs: [Job] = []
    private var count = 0
    /// Runs on the copy thread between the check of a path and its copy. Tests hold a copy with it.
    var beforeCopy: @Sendable (String) -> Void = { _ in }

    public init() {}

    func add(_ url: URL, _ task: Task<Void, Never>) -> Job {
        count += 1
        let job = Job(number: count, url: url, task: task)
        jobs.append(job)
        return job
    }

    func remove(_ number: Int) { jobs.removeAll { $0.number == number } }
}

extension Studio {
    /// The copy of `create` with a template: `createSession` on a utility thread, a job of `jobs`
    /// while it runs. A cancel of the caller ends it with `.template(.cancelled)`; a take start
    /// and the take disk check end it with `.templateYielded`. `progress` gets the fraction on the
    /// main actor.
    static func copyTemplate(
        _ template: URL, to package: URL, jobs: CopyJobs?, progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws(StudioError) {
        let beforeCopy: @Sendable (String) -> Void
        if let jobs { beforeCopy = jobs.beforeCopy } else { beforeCopy = { _ in } }
        let hop: @Sendable (Double) -> Void = { fraction in Task { @MainActor in progress(fraction) } }
        let task = utilityTask { isCancelled -> Result<Void, TemplateError> in
            withoutActuallyEscaping(isCancelled) { isCancelled -> Result<Void, TemplateError> in
                var seams = TemplateCopySeams()
                seams.beforeCopy = beforeCopy
                do throws(TemplateError) {
                    try createSession(
                        at: package, template: template, progress: hop, isCancelled: isCancelled, seams: seams)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
        }
        let job = jobs?.add(package, handle(task))
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if let job { jobs?.remove(job.number) }
        if case .failure(.cancelled) = result, job?.yielded == true { throw .templateYielded }
        do { try result.get() } catch { throw .template(error) }
    }
}

extension Studio {
    /// Saves the session of now as a template package at `url` (decision 0079): `newEpisode()`
    /// of the session, and its files from the package, with `copyNewEpisode`. It runs in the
    /// export job slot with the job URL at the template, so it throws `.busy` as `export`, and a
    /// take start in this studio and `settle()` end it with `.template(.cancelled)`, as for
    /// `export`; a take start and the take disk check of another studio on its volume end it with
    /// `.templateYielded`. `exportStop` gives the cause. A pending take throws `.busy`. `progress`
    /// gets the fraction on the main actor.
    public func saveTemplate(
        to url: URL, progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws(StudioError) {
        try checkIdle()
        guard pendingTake == nil, exportJob == nil, !settling else { throw .busy }
        let episode: NewEpisode
        do { episode = try session.newEpisode() } catch { throw .session(error) }
        exportNumber += 1
        exportStop = nil
        let number = exportNumber
        let hop: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.exportProgressed(number, fraction) }
        }
        let (canClone, written) = (environment.templateCanClone, environment.templateWritten)
        let task = jobTask { package, isCancelled -> Result<Void, TemplateError> in
            withoutActuallyEscaping(isCancelled) { isCancelled -> Result<Void, TemplateError> in
                let source: URL
                do throws(SessionFileError) { source = try package() } catch { return .failure(.read(error)) }
                var seams = TemplateCopySeams()
                seams.canClone = canClone
                seams.written = written
                do throws(TemplateError) {
                    try copyNewEpisode(
                        episode, files: source, to: url, progress: hop, isCancelled: isCancelled, seams: seams)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
        }
        exportJob = ExportJob(
            number: number, url: url, progress: 0, report: progress, task: Self.handle(task), isTemplate: true)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if exportJob?.number == number { exportJob = nil }
        if case .failure(.cancelled) = result, yieldedExport == number { throw .templateYielded }
        do { try result.get() } catch { throw .template(error) }
    }
}
