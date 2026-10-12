import DirigibleCore
import Foundation

/// Why a revert to a backup did not change `session.xml`.
package enum RevertError: Error {
    /// The backup cannot be read, is damaged, or is of a newer version.
    case backup(Backup, SessionFileError)
    /// The copy of the current `session.xml` failed. The CLI and MCP have no undo, so the revert
    /// is refused with no copy (decision 0043).
    case currentCopy(SessionFileError)
    /// The backup removes or changes a track that the recording arms.
    case session(SessionError)
}

/// The body of `backup revert` and of `backup_revert`.
package func revert(_ session: inout Session, to backup: Backup, under lock: PackageLock) throws(RevertError) {
    let target: Session
    do throws(RevertReadError) {
        target = try backup.readForRevert(under: lock)
    } catch {
        switch error {
        case .backup(let fault): throw .backup(backup, fault)
        case .currentCopy(let fault): throw .currentCopy(fault)
        }
    }
    do throws(SessionError) {
        session = try session.reverted(to: target)
    } catch {
        throw .session(error)
    }
}

/// The error text of `backup list` and `backup_list` for a package with no `session.xml`, so a
/// wrong path is not an empty list. Nil when the file is there.
package func missingSessionFile(_ package: URL, path: String) -> String? {
    guard access(package.appending(path: "session.xml").path, F_OK) != 0 else { return nil }
    return SessionFileError.readFailed(errno: errno).message(package: path)
}

/// The text of a bad backup name, for the CLI and MCP.
package let backupNameExpected = "a backup file name, for example session-20261009T081530.250Z.xml"
