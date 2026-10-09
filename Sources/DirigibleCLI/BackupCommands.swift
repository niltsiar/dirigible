import ArgumentParser
import DirigibleCore
import Foundation

/// The backups of `session.xml` in `Backups/` (decision 0043).
struct BackupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup", abstract: "List the backups of a session, and revert to one.",
        subcommands: [List.self, Revert.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write the backup file names, newest first.")
        @OptionGroup var package: PackageArgument

        func run() throws {
            if let message = missingSessionFile(package.url, path: package.path) {
                throw fail(message, code: packageError)
            }
            for backup in Backup.all(in: package.url) { print(backup.fileName) }
        }
    }

    struct Revert: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Revert the session to a backup. It keeps a backup of the replaced session first.")
        @OptionGroup var package: PackageArgument
        @Option(help: "The backup file name, as backup list writes it.", transform: parseBackup) var name: Backup

        func run() throws {
            try editPackage(package, refused: refused) { session, lock throws(RevertError) in
                try revert(&session, to: name, under: lock)
            }
        }

        /// A backup that cannot be read exits 2, as a `session.xml` that cannot be read.
        private func refused(_ error: RevertError) -> ExitCode {
            let message = error.message(package: package.path)
            return switch error {
            case .backup, .currentCopy: fail(message, code: packageError)
            case .session: fail(message, code: editRefused)
            }
        }
    }
}

/// Why a revert to a backup did not change `session.xml`.
enum RevertError: Error {
    /// The backup cannot be read, is damaged, or is of a newer version.
    case backup(Backup, SessionFileError)
    /// The copy of the current `session.xml` failed. The CLI and MCP have no undo, so the revert
    /// is refused with no copy (decision 0043).
    case currentCopy(SessionFileError)
    /// The backup removes or changes a track that the recording arms.
    case session(SessionError)
}

/// The body of `backup revert` and of `backup_revert`.
func revert(_ session: inout Session, to backup: Backup, under lock: PackageLock) throws(RevertError) {
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
func missingSessionFile(_ package: URL, path: String) -> String? {
    guard access(package.appending(path: "session.xml").path, F_OK) != 0 else { return nil }
    return SessionFileError.readFailed(errno: errno).message(package: path)
}

/// The text of a bad backup name, for the CLI and MCP.
let backupNameExpected = "a backup file name, for example session-20261009T081530.250Z.xml"

private func parseBackup(_ text: String) throws -> Backup {
    guard let backup = Backup(fileName: text) else { throw ValidationError("The name must be \(backupNameExpected).") }
    return backup
}
