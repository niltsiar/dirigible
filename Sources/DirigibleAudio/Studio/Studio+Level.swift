import DirigibleCore
import Foundation

extension Studio {
    /// Auto Level and Auto Level per Track (decision 0031): sets the gain of each clip of `clips`
    /// with `autoLevel`. A running play stops first, as at a take start. The measurement runs off
    /// the main actor; meanwhile every other entry point throws `.busy`. A change saves
    /// `session.xml` and records one undo entry in the same turn, so a Quit right after it keeps
    /// the level. A level that changes no gain saves nothing and records no entry. It returns the
    /// report and the level of each clip on each exit with no throw. A throw changes nothing. The
    /// transport is `.idle` after every exit.
    ///
    /// `agent` names the agent of an MCP level in its undo entry, and `progress` gets the fraction
    /// on the main actor (decision 0049). `cancelLevel()` or a cancel of the caller stops the
    /// measure at its next block; the flag is read last before the save, so a set flag throws
    /// `.levelCancelled` and saves nothing.
    @discardableResult
    public func level(
        _ clips: Set<ClipID>, _ mode: LevelMode, agent: AgentName? = nil,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws(StudioError) -> (report: LevelReport, levels: [ClipID: ClipLevel]) {
        try checkIdle()
        let stopped = endPlayForTake()
        let flags = ImportFlags()
        (transport, levelFlags) = (.leveling, flags)
        defer { (transport, levelFlags) = (.idle, nil) }
        let hop: @Sendable (Double) -> Void = { fraction in Task { @MainActor in progress(fraction) } }
        let result = await withTaskCancellationHandler {
            await serialized { () async -> Result<(report: LevelReport, levels: [ClipID: ClipLevel]), StudioError> in
                _ = await takePlayhead(stopped, nil)  // The Player stops.
                await environment.beforeFinalize()
                let (leveled, levels): (Session, [ClipID: ClipLevel])
                switch await levelClips(
                    clips, mode, of: session, lock: lock, progress: hop,
                    isCancelled: { [step = environment.loudnessBlock] in
                        step()
                        return flags.isCancelled
                    })
                {
                case .success(let value): (leveled, levels) = value
                case .failure(let error): return .failure(error)
                }
                if flags.isCancelled { return .failure(.levelCancelled) }
                let report = (report: LevelReport(levels, before: session), levels: levels)
                guard leveled != session else { return .success(report) }
                switch await writeSession(
                    leveled, lock: lock, previous: url, recordings: recordings, environment.saveSession)
                {
                case .success(let written):
                    url = written.package
                    backups = written.backups
                    recordLevel(leveled, agent: agent)
                    return .success(report)
                case .failure(let error):
                    return .failure(error)
                }
            }
        } onCancel: {
            flags.cancel(yielding: false)
        }
        return try result.get()
    }

    /// The Cancel of the level banner (decision 0049): sets the flag of the running level, with no
    /// wait. The level ends at its next block and saves nothing.
    public func cancelLevel() { levelFlags?.cancel(yielding: false) }
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
