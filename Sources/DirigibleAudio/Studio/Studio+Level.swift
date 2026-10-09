import DirigibleCore
import Foundation

extension Studio {
    /// Auto Level and Auto Level per Track (decision 0031): sets the gain of each clip of `clips`
    /// with `autoLevel`. A running play stops first, as at a take start. The measurement runs off
    /// the main actor; meanwhile every other entry point throws `.busy`. A change saves
    /// `session.xml` and records one undo entry in the same turn, so a Quit right after it keeps
    /// the level. A throw changes nothing. The transport is `.idle` after every exit.
    public func level(_ clips: Set<ClipID>, _ mode: LevelMode) async throws(StudioError) {
        try checkIdle()
        let stopped = endPlayForTake()
        transport = .leveling
        defer { transport = .idle }
        let error = await serialized { () async -> StudioError? in
            _ = await takePlayhead(stopped, nil)  // The Player stops.
            await environment.beforeFinalize()
            let leveled: Session
            switch await levelClips(clips, mode, of: session, lock: lock) {
            case .success(let session): leveled = session
            case .failure(let error): return error
            }
            guard leveled != session else { return nil }
            switch await writeSession(
                leveled, lock: lock, previous: url, recordings: recordings, environment.saveSession)
            {
            case .success(let written):
                url = written.package
                backups = written.backups
                recordLevel(leveled)
                return nil
            case .failure(let error):
                return error
            }
        }
        if let error { throw error }
    }
}

/// `autoLevel` off the main actor, in the package that `lock` holds now.
@concurrent nonisolated func levelClips(_ clips: Set<ClipID>, _ mode: LevelMode, of session: Session, lock: PackageLock)
    async -> Result<Session, StudioError>
{
    dispatchPrecondition(condition: .notOnQueue(.main))
    do throws(SessionFileError) {
        return .success(autoLevel(clips, mode, of: session, in: try lock.package()).session)
    } catch {
        return .failure(.file(error))
    }
}
