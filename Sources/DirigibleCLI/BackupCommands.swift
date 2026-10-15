import ArgumentParser
import DirigibleCore
import DirigibleMCP
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
            try editPackage(package, ripple: false, refused: refused) { session, lock throws(RevertError) in
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

private func parseBackup(_ text: String) throws -> Backup {
    guard let backup = Backup(fileName: text) else { throw ValidationError("The name must be \(backupNameExpected).") }
    return backup
}
