import DirigibleAudio
import DirigibleCore
import Foundation

/// The output of `file prune` and of `file_prune` (decision 0047).
package struct PruneOutput: Sendable {
    /// The lines of the list or of the moves, then the totals.
    package let lines: [String]
    /// One line for each file that did not move to the Trash.
    package let failed: [String]
}

/// The body of `file prune` and of `file_prune`. It holds the package lock from the read to the
/// last move, refuses a pending take, and scans. With `dryRun`, it writes nothing. Else, when the
/// scan has an item and the package is archived, it unarchives first (`unarchiveForWrite`,
/// decision 0072) and scans again. Then it removes the leftover temporary files and moves the
/// unused files to the Trash.
package func prunePackage(_ package: URL, dryRun: Bool) throws(EditFailure<UnusedFilesError>) -> PruneOutput {
    try PackageLock.withLock(package, locked: EditFailure<UnusedFilesError>.file) {
        lock throws(EditFailure<UnusedFilesError>) in
        var session: Session
        do throws(SessionFileError) {
            session = try Session(contentsOf: package)
        } catch {
            throw .file(error)
        }
        guard session.recording == nil else { throw .pendingTake }
        func scanned() throws(EditFailure<UnusedFilesError>) -> UnusedFiles {
            do throws(UnusedFilesError) {
                return try UnusedFiles(scanningWithCaptures: session, keptBy: [], in: package)
            } catch {
                throw .body(error)
            }
        }
        var scan = try scanned()
        // The step writes a new file at each `<stem>.wav`, and the move checks each identity
        // against its scan.
        if !dryRun, !scan.items.isEmpty, needsUnarchive(session) {
            let before = session
            do throws(ArchiveFault) {
                try unarchiveForWrite(&session, before: before, in: package, under: lock, log: standardErrorLine)
            } catch {
                throw .archive(error)
            }
            scan = try scanned()
        }
        var lines = scan.damagedBackups.map { "Damaged backup, it keeps no file: \(backupsFolderName)/\($0.fileName)" }
        lines += scan.notFiles.map { "Not a regular file, it stays: \(clipsFolderName)/\($0)" }
        let kept = "Kept for a backup: \(scan.kept.count) (\(scan.kept.bytes) bytes)"
        guard !dryRun else {
            lines += scan.items.map { "\($0.path)\t\($0.bytes) bytes" }
            return PruneOutput(lines: lines + ["Unused files: \(total(scan.items))", kept], failed: [])
        }
        session.removeTemporaryFiles(in: package)
        let report: PruneReport
        do throws(UnusedFilesError) {
            report = try scan.prune(&session) { session throws(SessionFileError) in try session.write(under: lock) }
        } catch {
            throw .body(error)
        }
        lines += report.moved.map { "\($0.item.path)\t\($0.item.bytes) bytes\t\($0.trashURL.path)" }
        lines.append(
            "Moved to the Trash: \(total(report.moved.map(\.item))). The space comes back when you empty the Trash.")
        let failed = report.failed.map {
            let reason =
                $0.fault == .replaced
                ? "another file took its place after the scan."
                : NSError(domain: $0.fault.domain, code: $0.fault.code).localizedDescription
            return "\($0.item.path) did not move to the Trash: \(reason)"
        }
        return PruneOutput(lines: lines + [kept], failed: failed)
    }
}

private func total(_ items: [UnusedFiles.Item]) -> String {
    "\(items.count) (\(items.reduce(0) { $0 + $1.bytes }) bytes)"
}
