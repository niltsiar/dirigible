import DirigibleCore
import Foundation

/// Whether an edit ripples, so that a split take refuses it. A literal is a fixed answer. A plan
/// whose cuts depend on the sample rate asks the session that the edit opens.
package struct RippleNeed: ExpressibleByBooleanLiteral, Sendable {
    package let isNeeded: @Sendable (Session) -> Bool
    package init(booleanLiteral value: Bool) { isNeeded = { _ in value } }
    package init(_ isNeeded: @escaping @Sendable (Session) -> Bool) { self.isNeeded = isNeeded }
}

/// Why a package edit changed nothing. The CLI maps each case to an exit code, and an MCP tool
/// to an error result.
package enum EditFailure<Body: Error>: Error {
    /// The lock is held (`.locked`, decision 0012), or the read or the save failed.
    case file(SessionFileError)
    /// `session.xml` holds `<recording>`: a take that is not finalized (decision 0004).
    case pendingTake
    /// A ripple edit on a take with some segments on the timeline and some not (decision 0037).
    case splitTake
    /// The error of the edit body.
    case body(Body)
    /// The unarchive step before the save or the body (decision 0072).
    case archive(ArchiveFault)
}

/// Takes the package lock (decision 0012), reads the package, removes the leftover temporary
/// files of a crashed save (after the read, so a newer package does not change: decision 0024
/// P4), refuses a pending take, removes the raw CAF of each segment with a finalize record
/// (decision 0071; a fault goes to `log()`), refuses a split take when `ripple` is true, applies
/// `body`, and saves. With `writeUnchanged` false, or on an archived package, it does not save a
/// session that `body` did not change. The lock is held until the save ends. An archived package
/// unarchives first (`unarchiveForWrite`, decision 0072): after `body` and before the save when `touchesClips` is
/// false, and before `body` when `body` opens or writes a clip file or copies `session.xml` to
/// `Backups/`. `session.xml` does not change when a step fails, except after a fault of a
/// `touchesClips` body: the package then stays unarchived with the session facts of before. A save
/// with `backups` `.standard` and a backup due can add a backup, and a save can delete the
/// oldest backup before the replace. With no `backups`, the package of the Favorites store gets `.store`
/// and each other package gets `.standard` (`Favorites.backups(for:environment:)`, decision 0081). A refused
/// revert can leave the kept copy of the current file (decision 0043). With `whenMissing`, a package
/// folder with no `session.xml` (ENOENT at the read) edits the session that it gives, and the save
/// writes it under the lock: the Favorites store after a crash during its first write.
package func editPackageCore<Result, Failure: Error>(
    _ package: URL, ripple: RippleNeed, touchesClips: Bool, writeUnchanged: Bool = true, backups: BackupPolicy? = nil,
    log: () -> DiagnosticLog, whenMissing: (() -> Session)? = nil,
    _ body: (inout Session, PackageLock) throws(Failure) -> Result
) throws(EditFailure<Failure>) -> Result {
    try PackageLock.withLock(package, locked: EditFailure<Failure>.file) { lock throws(EditFailure<Failure>) in
        var session: Session
        do throws(SessionFileError) {
            session = try Session(contentsOf: package)
        } catch {
            guard error == .readFailed(errno: ENOENT), let whenMissing else { throw .file(error) }
            session = whenMissing()
        }
        session.removeTemporaryFiles(in: package)
        guard session.recording == nil else { throw .pendingTake }
        if lock.isHeld { removeRecordedRawCaptures(of: session, in: package, log: log) }
        if ripple.isNeeded(session), rippleBlocked(in: package, session: session) { throw .splitTake }
        var before = session
        func unarchive() throws(EditFailure<Failure>) {
            do throws(ArchiveFault) {
                try unarchiveForWrite(&session, before: before, in: package, under: lock, log: standardErrorLine)
            } catch {
                throw .archive(error)
            }
        }
        if touchesClips {
            try unarchive()
            before = session
        }
        let result: Result
        do throws(Failure) {
            result = try body(&session, lock)
        } catch {
            throw .body(error)
        }
        // A save of an unchanged archived session would unarchive it, and a due backup would hold
        // the archived file.
        if session == before, !writeUnchanged || needsUnarchive(before) { return result }
        if !touchesClips { try unarchive() }
        do throws(SessionFileError) {
            // The package that the lock holds, also after a rename (decision 0014).
            let policy = backups ?? Favorites.backups(for: package, environment: ProcessInfo.processInfo.environment)
            try session.write(under: lock, backups: policy)
        } catch {
            throw .file(error)
        }
        return result
    }
}
