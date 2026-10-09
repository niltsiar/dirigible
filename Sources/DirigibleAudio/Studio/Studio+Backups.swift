import DirigibleCore
import Foundation

extension Studio {
    /// Reverts the session to `backup` as one undo entry that keeps the pending take (decision
    /// 0043). In its turn of the write chain, it first throws the last save error, so the copy
    /// that it keeps of the current file is the session in memory. Throws `.busy` while a take,
    /// a finalize, a placement, a level, or an import runs, also one that starts during the read.
    /// Throws `.file` for a newer, damaged, or missing backup, and `.session(.trackInRecording)`
    /// for a backup that removes an armed track or changes its route or layout. A throw leaves the
    /// session unchanged.
    public func revert(to backup: Backup) async throws(StudioError) {
        try checkIdle()
        let read = await serialized { () async -> Result<Session, StudioError> in
            if let saveError { return .failure(saveError) }
            let result = await readBackup(backup, lock: lock)
            if case .success(let read) = result { backups = read.backups }
            return result.map(\.session)
        }
        let target = try read.get()
        // `edit` runs `checkIdle` again: a take can start during the read (AGENTS.md, Actors).
        try edit { session throws(SessionError) in session = try session.reverted(to: target) }
    }
}

/// The revert read off the main actor: the backup, the kept copy of the current file, and the
/// list after it.
@concurrent nonisolated func readBackup(_ backup: Backup, lock: PackageLock) async
    -> Result<(session: Session, backups: [Backup]), StudioError>
{
    dispatchPrecondition(condition: .notOnQueue(.main))
    do throws(SessionFileError) {
        let session = try backup.readForRevert(under: lock)
        return .success((session, Backup.all(in: try lock.package())))
    } catch {
        return .failure(.file(error))
    }
}

/// The backup at the close of a window, off the main actor. Returns the list after it, or nil
/// when the package left its volume.
@concurrent nonisolated func keepBackupAtClose(_ lock: PackageLock) async -> [Backup]? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let package = try? lock.package() else { return nil }
    Backup.keepAtClose(in: package)
    return Backup.all(in: package)
}
