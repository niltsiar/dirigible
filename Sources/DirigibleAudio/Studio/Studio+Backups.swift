import DirigibleCore
import Foundation

extension Studio {
    /// Reverts the session to `backup` as one undo entry that keeps the pending take (decision
    /// 0043). In its turn of the write chain, it first throws the last save error, so the copy
    /// that it keeps of the current file is the session in memory. Throws `.busy` while a take,
    /// a finalize, a placement, a level, or an import runs, also one that starts during the read.
    /// Throws `.file` for a newer, damaged, or missing backup, and when the copy of the current
    /// file fails: the revert keeps that copy first. Throws `.session(.trackInRecording)`
    /// for a backup that removes an armed track or changes its route or layout. A throw leaves the
    /// session unchanged. Throws `.busy` also when an edit, an undo, or a redo came after the
    /// call: the kept copy can miss that change. After a revert, it checks the pool files again.
    public func revert(to backup: Backup) async throws(StudioError) {
        let revision = sessionRevision
        try checkIdle()
        let read = await serialized { () async -> Result<Void, StudioError> in
            if let saveError { return .failure(saveError) }
            let target: Session
            switch await readBackup(backup, lock: lock) {
            case .success(let read): (target, backups) = (read.session, read.backups)
            case .failure(let error): return .failure(error)
            }
            // An edit, an undo, or a redo after the call can be missing from the kept copy, also
            // when a later change sets the value back, so the revision decides (AGENTS.md, Actors).
            // The edit runs in this turn, so no other job runs between the check and it.
            guard sessionRevision == revision else { return .failure(.busy) }
            do throws(StudioError) {
                try edit { session throws(SessionError) in session = try session.reverted(to: target) }
            } catch {
                return .failure(error)
            }
            return .success(())
        }
        try read.get()
        // The backup can name pool files that are not on the disk, as at open (decision 0016).
        await checkMedia()
    }
}

/// The revert read off the main actor: the backup, the kept copy of the current file, and the
/// list after it.
@concurrent nonisolated func readBackup(_ backup: Backup, lock: PackageLock) async
    -> Result<(session: Session, backups: [Backup]), StudioError>
{
    dispatchPrecondition(condition: .notOnQueue(.main))
    let session: Session
    do throws(RevertReadError) {
        session = try backup.readForRevert(under: lock)
    } catch {
        // The window alert has one text for each file error, with no file name.
        switch error {
        case .backup(let fault), .currentCopy(let fault): return .failure(.file(fault))
        }
    }
    do throws(SessionFileError) {
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
