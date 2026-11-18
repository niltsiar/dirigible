import DirigibleCore
import Foundation

extension Studio {
    /// Auto Level and Auto Level per Track (decision 0031): sets the gain of each clip of `clips`
    /// with `autoLevel`, through `runReadJob` on the `.leveling` transport. It returns the report
    /// and the level of each clip on each exit with no throw. A cancel throws `.levelCancelled`.
    @discardableResult
    public func level(
        _ clips: Set<ClipID>, _ mode: LevelMode, agent: AgentName? = nil,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws(StudioError) -> (report: LevelReport, levels: [ClipID: ClipLevel]) {
        try checkIdle()
        return try await runReadJob(
            .leveling, cancelled: .levelCancelled, agent: agent, progress: progress,
            read: { session, lock, progress, isCancelled in
                await levelClips(clips, mode, of: session, lock: lock, progress: progress, isCancelled: isCancelled)
            },
            apply: { session, read in (read.0, (report: LevelReport(read.1, before: session), levels: read.1)) })
    }

    /// The body of a level, a duck, a silence scan, and a sync (decisions 0031, 0049, 0060, 0066, and 0076). A running play stops
    /// first, as at a take start. `read` runs off the main actor on the session of the turn, while
    /// `job` holds the transport and every other entry point throws `.busy`; `apply` makes the new
    /// session and the value on the main actor. A change saves `session.xml` and records one undo
    /// entry with `agent` in the same turn, so a Quit right after it keeps the change. A job that
    /// changes nothing saves nothing and records no entry. `progress` gets the fraction on the main
    /// actor. `cancelReadJob()` or a cancel of the caller stops the read at its next block; the
    /// flag is read last before `apply`, so a set flag throws `cancelled` and saves nothing. A
    /// throw changes nothing. The transport is `.idle` after every exit.
    func runReadJob<Read: Sendable, Value>(
        _ job: Transport, cancelled: StudioError, agent: AgentName?,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
        read:
            @escaping @Sendable (
                Session, PackageLock, _ progress: @escaping @Sendable (Double) -> Void,
                _ isCancelled: @escaping @Sendable () -> Bool
            ) async -> Result<Read, StudioError>,
        apply: (Session, Read) throws(StudioError) -> (Session, Value)
    ) async throws(StudioError) -> Value {
        let stopped = endPlayForTake()
        let flags = ImportFlags()
        (transport, readJobFlags) = (job, flags)
        defer { (transport, readJobFlags) = (.idle, nil) }
        let hop: @Sendable (Double) -> Void = { fraction in Task { @MainActor in progress(fraction) } }
        let result = await withTaskCancellationHandler {
            await serialized { () async -> Result<Value, StudioError> in
                _ = await takePlayhead(stopped, nil)  // The Player stops.
                await environment.beforeFinalize()
                let value: Read
                switch await read(
                    session, lock, hop,
                    { [step = environment.loudnessBlock] in
                        step()
                        return flags.isCancelled
                    })
                {
                case .success(let read): value = read
                case .failure(let error): return .failure(error)
                }
                if flags.isCancelled { return .failure(cancelled) }
                let (changed, output): (Session, Value)
                do throws(StudioError) { (changed, output) = try apply(session, value) } catch {
                    return .failure(error)
                }
                guard changed != session else { return .success(output) }
                switch await writeSession(
                    changed, lock: lock, previous: url, recordings: recordings, environment.saveSession)
                {
                case .success(let written):
                    url = written.package
                    backups = written.backups
                    recordLevel(changed, agent: agent)
                    return .success(output)
                case .failure(let error):
                    return .failure(error)
                }
            }
        } onCancel: {
            flags.cancel(yielding: false)
        }
        return try result.get()
    }

    /// The Cancel of the level, duck, silence scan, and sync banners (decisions 0049, 0060, 0066, and 0076): sets
    /// the flag of the running job, with no wait. It ends at its next block and saves nothing.
    public func cancelReadJob() { readJobFlags?.cancel(yielding: false) }
}

/// `autoLevel` off the main actor, in the package that `lock` holds now.
@concurrent nonisolated func levelClips(
    _ clips: Set<ClipID>, _ mode: LevelMode, of session: Session, lock: PackageLock,
    progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool
) async -> Result<(Session, [ClipID: ClipLevel]), StudioError> {
    dispatchPrecondition(condition: .notOnQueue(.main))
    do throws(SessionFileError) {
        let package = try lock.package()
        return .success(autoLevel(clips, mode, of: session, in: package, progress: progress, isCancelled: isCancelled))
    } catch {
        return .failure(.file(error))
    }
}
