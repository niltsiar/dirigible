import DirigibleAudio
import DirigibleCore
import Foundation

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
}

/// Takes the package lock (decision 0012), reads the package, removes the leftover temporary
/// files of a crashed save (after the read, so a newer package does not change: decision 0024
/// P4), refuses a pending take, removes the raw CAF of each segment with a finalize record
/// (decision 0071; a fault goes to `log()`), refuses a split take when `ripple` is true, applies
/// `body`, and saves. With `writeUnchanged` false, it does not save a session that `body` did not
/// change. The lock is held until the save ends. `session.xml` does not change when a step fails.
/// A due save can add a backup and delete the oldest backup before the replace, and a refused
/// revert can leave the kept copy of the current file (decision 0043).
package func editPackageCore<Result, Failure: Error>(
    _ package: URL, ripple: RippleNeed, writeUnchanged: Bool = true, log: () -> DiagnosticLog,
    _ body: (inout Session, PackageLock) throws(Failure) -> Result
) throws(EditFailure<Failure>) -> Result {
    try PackageLock.withLock(package, locked: EditFailure<Failure>.file) { lock throws(EditFailure<Failure>) in
        var session: Session
        do throws(SessionFileError) {
            session = try Session(contentsOf: package)
        } catch {
            throw .file(error)
        }
        session.removeTemporaryFiles(in: package)
        guard session.recording == nil else { throw .pendingTake }
        removeRecordedRawCaptures(of: session, in: package, log: log)
        if ripple.isNeeded(session), rippleBlocked(in: package, session: session) { throw .splitTake }
        let before = session
        let result: Result
        do throws(Failure) {
            result = try body(&session, lock)
        } catch {
            throw .body(error)
        }
        if !writeUnchanged && session == before { return result }
        do throws(SessionFileError) {
            // The package that the lock holds, also after a rename (decision 0014).
            try session.write(under: lock)
        } catch {
            throw .file(error)
        }
        return result
    }
}
