import DirigibleCore
import Foundation

extension Studio {
    /// Auto Level and Auto Level per Track (decision 0031): sets the gain of each clip of `clips`
    /// with `autoLevel`. A running play stops first, as at a take start. The measurement runs off
    /// the main actor; meanwhile every other entry point throws `.busy`. A change saves
    /// `session.xml` and records one undo entry in the same turn, so a Quit right after it keeps
    /// the level. A level that changes no gain saves nothing and records no entry. It returns the
    /// report of the level on each exit with no throw. A throw changes nothing. The transport is
    /// `.idle` after every exit.
    @discardableResult
    public func level(_ clips: Set<ClipID>, _ mode: LevelMode) async throws(StudioError) -> LevelReport {
        try checkIdle()
        let stopped = endPlayForTake()
        transport = .leveling
        defer { transport = .idle }
        let result = await serialized { () async -> Result<LevelReport, StudioError> in
            _ = await takePlayhead(stopped, nil)  // The Player stops.
            await environment.beforeFinalize()
            let (leveled, report): (Session, LevelReport)
            switch await levelClips(clips, mode, of: session, lock: lock) {
            case .success(let value): (leveled, report) = value
            case .failure(let error): return .failure(error)
            }
            guard leveled != session else { return .success(report) }
            switch await writeSession(
                leveled, lock: lock, previous: url, recordings: recordings, environment.saveSession)
            {
            case .success(let written):
                url = written.package
                backups = written.backups
                recordLevel(leveled)
                return .success(report)
            case .failure(let error):
                return .failure(error)
            }
        }
        return try result.get()
    }
}

/// `autoLevel` off the main actor, in the package that `lock` holds now.
@concurrent nonisolated func levelClips(_ clips: Set<ClipID>, _ mode: LevelMode, of session: Session, lock: PackageLock)
    async -> Result<(Session, LevelReport), StudioError>
{
    dispatchPrecondition(condition: .notOnQueue(.main))
    do throws(SessionFileError) {
        let (leveled, levels) = autoLevel(clips, mode, of: session, in: try lock.package())
        return .success((leveled, LevelReport(levels, before: session)))
    } catch {
        return .failure(.file(error))
    }
}
