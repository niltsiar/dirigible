import DirigibleCore
import Foundation

/// The unarchive-first step of a CLI or MCP write job (decision 0072): `editPackageCore` and
/// `prunePackage` call it under the package lock. It does nothing when `before` is not archived
/// (`needsUnarchive`). Else it converts the FLAC of each pool file of `before` and of `session`,
/// so the FLAC of an entry that the body dropped goes too. It saves `before` with no attribute and
/// with no backup, and sets `session.archive` to nil; the caller then saves `session` with its own
/// backup rule, so no backup holds the archived file. `log` gets the progress lines and one line
/// for each FLAC that stays as damaged.
package func unarchiveForWrite(
    _ session: inout Session, before: Session, in package: URL, under lock: PackageLock, log: (String) -> Void
) throws(ArchiveFault) {
    try unarchiveForWrite(&session, before: before, in: package, under: lock, log: log, seams: ArchiveSeams())
}

func unarchiveForWrite(
    _ session: inout Session, before: Session, in package: URL, under lock: PackageLock, log: (String) -> Void,
    seams: ArchiveSeams
) throws(ArchiveFault) {
    guard needsUnarchive(before) else { return }
    var saved = before
    let report = try unarchivePackage(
        &saved, also: Array(session.files.values), in: package, cache: PeakFile.folder,
        progress: { log("unarchive: \(Int(($0 * 100).rounded()))%") }, isStopped: { false },
        save: { session throws(SessionFileError) in try session.write(under: lock, backups: .none) }, seams: seams)
    let lengths = Dictionary(
        (Array(before.files.values) + session.files.values).map { ($0.path, $0.length) },
        uniquingKeysWith: { a, _ in a })
    for (path, reason) in report.kept.sorted(by: { $0.key < $1.key }) {
        guard case .damaged(let frames) = reason else { continue }
        log(damagedLine(path, frames: frames, length: lengths[path]))
    }
    session.archive = nil
}

/// The line of a FLAC that a package job kept as damaged: its name, the frames that decoded, and
/// the length of its pool entry, when one names it.
package func damagedLine(_ path: String, frames: Frames, length: Frames?) -> String {
    let name = "\(clipsFolderName)/\(archivedPath(of: path) ?? path)"
    guard let length else { return "damaged, kept as FLAC: \(name), \(frames.count) frames decoded" }
    return "damaged, kept as FLAC: \(name), \(frames.count) of \(length.count) frames decoded"
}

/// Writes one line on stderr: the sink of the step lines of `editPackageCore` and `prunePackage`.
package func standardErrorLine(_ line: String) {
    try? FileHandle.standardError.write(contentsOf: Data("\(line)\n".utf8))
}
