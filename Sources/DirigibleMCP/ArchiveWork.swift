import DirigibleAudio
import DirigibleCore
import Foundation

/// The job of `file archive` and `file_archive`, or of `file unarchive` and `file_unarchive`
/// (decision 0072).
package enum ArchiveDirection: Sendable {
    case archive
    case unarchive
}

/// The output of a package job.
package struct ArchiveOutput: Sendable {
    /// The line of each file that stays (for an unarchive, not a damaged one), the count, and for
    /// an archive the bytes lines.
    package let lines: [String]
    /// One line for each FLAC that the job kept as damaged.
    package let failed: [String]
}

/// The `archive:` line of `info` and the `archive` key of `info --json` and `session_info`: the
/// form, the count of pool files in FLAC, and the count of the other pool files.
package struct ArchiveState: Encodable, Sendable {
    let form: String
    let flacFiles: Int
    let kept: Int

    /// Nil for a session with no `archive` attribute. It reads the names in `Clips/` of `package`.
    package init?(_ session: Session, in package: URL) {
        guard let archive = session.archive else { return nil }
        form = archive.rawValue
        flacFiles = session.files.values.count { poolFileName($0, in: package).form == .flac }
        kept = session.files.count - flacFiles
    }

    var text: String { "archive: \(form), \(flacFiles) files in FLAC, \(kept) kept" }
}

/// The rule of the help of `file archive` and of the description of `file_archive`.
package let archiveStoreRule = "The Favorites store is never archived."

/// The session of `package` for a command or tool that reads samples (export, render, stems,
/// loudness, meter, silences, nearest pause). A FLAC read misses the time limits of an export
/// (decision 0072), so an archived package unarchives first (`unarchiveForWrite`), under the lock
/// for that step only. The job then reads with no lock, as on a working package.
package func readUnarchived(_ package: URL, log: (String) -> Void) throws(ArchiveFault) -> Session {
    func read() throws(ArchiveFault) -> Session {
        do throws(SessionFileError) { return try Session(contentsOf: package) } catch { throw .file(error) }
    }
    let session = try read()
    guard needsUnarchive(session) else { return session }
    return try PackageLock.withLock(package, locked: ArchiveFault.file) { lock throws(ArchiveFault) in
        let before = try read()
        var locked = before
        try unarchiveForWrite(&locked, before: before, in: package, under: lock, log: log)
        return locked
    }
}

/// `readUnarchived` with the error text of a tool.
func readForSamples(_ package: URL, path: String) throws(ToolError) -> Session {
    do throws(ArchiveFault) { return try readUnarchived(package, log: standardErrorLine) } catch {
        throw ToolError(error.message(package: path))
    }
}

/// The body of `file archive`, `file unarchive`, and their tools. It holds the package lock for the
/// whole job, removes the leftover temporary files after the read (decision 0024 P4), and saves
/// `session.xml` with no backup, so no backup holds the archived file. `log` gets the progress
/// lines.
package func runArchiveJob(
    _ direction: ArchiveDirection, on package: URL, log: (String) -> Void
) throws(ArchiveFault) -> ArchiveOutput {
    try PackageLock.withLock(package, locked: ArchiveFault.file) { lock throws(ArchiveFault) in
        var session: Session
        do throws(SessionFileError) {
            session = try Session(contentsOf: package)
        } catch {
            throw .file(error)
        }
        session.removeTemporaryFiles(in: package)
        func save(_ session: Session) throws(SessionFileError) -> URL { try session.write(under: lock, backups: .none) }
        func progress(_ fraction: Double) {
            log("\(direction == .archive ? "archive" : "unarchive"): \(Int((fraction * 100).rounded()))%")
        }
        switch direction {
        case .archive:
            let report = try archivePackage(
                &session, in: package, cache: PeakFile.folder, progress: progress, save: save)
            return ArchiveOutput(lines: keptLines(report) + archiveLines(report), failed: [])
        case .unarchive:
            let lengths = Dictionary(session.files.values.map { ($0.path, $0.length) }, uniquingKeysWith: { a, _ in a })
            let report = try unarchivePackage(
                &session, in: package, cache: PeakFile.folder, progress: progress, save: save)
            let damaged = report.kept.sorted { $0.key < $1.key }.compactMap { path, reason -> String? in
                guard case .damaged(let frames) = reason else { return nil }
                return damagedLine(path, frames: frames, length: lengths[path])
            }
            return ArchiveOutput(
                lines: keptLines(report, damaged: false) + ["Converted to WAV: \(report.converted.count) files."],
                failed: damaged)
        }
    }
}

/// One line for each pool file that stays in its form; with `damaged` false, not for a damaged
/// file, which the caller reports as a fault.
private func keptLines(_ report: ArchiveReport, damaged: Bool = true) -> [String] {
    report.kept.sorted { $0.key < $1.key }.compactMap { path, reason -> String? in
        let text: String
        switch reason {
        case .missing: text = "missing"
        case .notWAV: text = "not a WAV file"
        case .notArchivable: text = "not a 24-bit WAV of the session rate"
        case .damaged(let frames):
            guard damaged else { return nil }
            text = "damaged, \(frames.count) frames decoded"
        }
        return "Kept: \(clipsFolderName)/\(path), \(text)"
    }
}

/// The count and the bytes of an archive (run criterion C12). The freed bytes do not count the
/// data of a WAV that a clone shares, and an APFS snapshot keeps the data of a freed file.
private func archiveLines(_ report: ArchiveReport) -> [String] {
    var lines = ["Converted to FLAC: \(report.converted.count) files."]
    guard !report.converted.isEmpty else { return lines }
    let net = report.bytesFreed - report.bytesWritten
    lines.append("Freed: \(report.bytesFreed) bytes. Written: \(report.bytesWritten) bytes. Net: \(net) bytes.")
    lines.append(
        net > 0
            ? "An APFS snapshot of the volume can keep these bytes in use until macOS deletes the snapshot."
            : "The archive freed no disk space: the WAV files share their data with a copy.")
    return lines
}
