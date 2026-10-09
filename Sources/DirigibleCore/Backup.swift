import Foundation

/// The folder of the backups in a package (decision 0043).
package let backupsFolderName = "Backups"

/// One backup of `session.xml` in `Backups/` (decision 0043). The value is a name, not a path:
/// each call gets the package path from its caller, so a rename of the package changes nothing.
public struct Backup: Hashable, Comparable, Sendable {
    /// The time of the copied `session.xml`, in milliseconds since 1970. An integer, so a name
    /// and a compare never round.
    let milliseconds: Int64

    /// The modification time of the copied `session.xml`, to the millisecond.
    public var saved: Date { Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000) }

    /// `session-<UTC yyyyMMdd'T'HHmmss.SSS'Z'>.xml`. It has no colon, so exFAT and SMB accept it.
    public var fileName: String {
        var (seconds, millisecond) = milliseconds.quotientAndRemainder(dividingBy: 1000)
        if millisecond < 0 { (seconds, millisecond) = (seconds - 1, millisecond + 1000) }
        var time = time_t(seconds)
        var parts = tm()
        gmtime_r(&time, &parts)
        return String(
            format: "session-%04d%02d%02dT%02d%02d%02d.%03dZ.xml", parts.tm_year + 1900, parts.tm_mon + 1,
            parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec, Int32(millisecond))
    }

    /// Nil for a name that does not parse, or that is not the name of its own date.
    public init?(fileName: String) {
        guard let match = fileName.wholeMatch(of: /session-(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)\.(\d{3})Z\.xml/),
            let year = Int32(match.1), let month = Int32(match.2), let day = Int32(match.3),
            let hour = Int32(match.4), let minute = Int32(match.5), let second = Int32(match.6),
            let millisecond = Int64(match.7)
        else { return nil }
        var parts = tm()
        (parts.tm_year, parts.tm_mon, parts.tm_mday) = (year - 1900, month - 1, day)
        (parts.tm_hour, parts.tm_min, parts.tm_sec) = (hour, minute, second)
        // timegm accepts month 13 as the next January, so the name must come back the same.
        milliseconds = Int64(timegm(&parts)) * 1000 + millisecond
        guard self.fileName == fileName else { return nil }
    }

    /// Truncates to the millisecond.
    init(saved: Date) { milliseconds = Int64((saved.timeIntervalSince1970 * 1000).rounded(.down)) }

    init(_ time: timespec) { milliseconds = Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000 }

    public static func < (a: Backup, b: Backup) -> Bool { a.milliseconds < b.milliseconds }

    /// The backups in `Backups/` of `package`, newest first. A name that does not parse is not a
    /// backup. No folder, or a read error, gives an empty list. It reads names only, so a caller
    /// without the lock can call it.
    public static func all(in package: URL) -> [Backup] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder(of: package).path)) ?? []
        return names.compactMap(Backup.init(fileName:)).sorted(by: >)
    }

    static func folder(of package: URL) -> URL { package.appending(path: backupsFolderName) }

    /// Copies `session.xml` of `package` to `Backups/<name of its mtime>` with the durable write
    /// of a save. Returns nil and copies nothing when a backup has the same bytes, so the caller
    /// prunes only after a new copy. Only a lock holder calls it.
    static func keep(in package: URL) throws(SessionFileError) -> Backup? {
        let source = package.appending(path: "session.xml")
        var info = stat()
        guard stat(source.path, &info) == 0 else { throw .readFailed(errno: errno) }
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw .readFailed(errno: posixCode(of: error))
        }
        let folder = folder(of: package)
        if mkdir(folder.path, 0o755) == 0 {
            // The new folder is an entry in the package folder, which a power loss can lose too.
            if let code = fullFlush(path: package.path) { throw .writeFailed(step: "fsync", errno: code) }
        } else if errno != EEXIST {
            throw .writeFailed(step: "mkdir", errno: errno)
        }
        if all(in: package).contains(where: { (try? Data(contentsOf: folder.appending(path: $0.fileName))) == data }) {
            return nil
        }
        let backup = Backup(info.st_mtimespec)
        try replaceDurably(folder.appending(path: backup.fileName), with: data)
        return backup
    }

    /// Deletes each backup after the `count` newest. It counts only the names that are not after
    /// `newest`, so names of a clock fault never push the new backup out. It never deletes a name
    /// that does not parse (decision 0024 P10) or a backup of a newer version (0024 P4).
    static func prune(in package: URL, keeping count: Int, after newest: Backup) {
        let folder = folder(of: package)
        for old in all(in: package).filter({ $0 <= newest }).dropFirst(count) {
            let url = folder.appending(path: old.fileName)
            if let data = try? Data(contentsOf: url), isNewer(data) { continue }
            unlink(url.path)
        }
    }

    private static func isNewer(_ data: Data) -> Bool {
        do {
            _ = try Session(xml: data)
        } catch .unsupportedVersion {
            return true
        } catch {
            return false
        }
        return false
    }
}

/// When a lock-holder save keeps a backup, and how many stay (decision 0043).
struct BackupPolicy: Sendable {
    /// Seconds from the newest backup to the replaced file.
    var interval: TimeInterval
    /// The backups that a prune keeps.
    var count: Int
    static let standard = BackupPolicy(interval: 600, count: 20)

    /// True when no backup is given, or when `replacing` is `interval` or more after `newest`.
    /// Both are file times, so one clock decides.
    func isDue(newest: Backup?, replacing: Backup) -> Bool {
        guard let newest else { return true }
        return replacing.milliseconds - newest.milliseconds >= Int64(interval * 1000)
    }

    /// Keeps a backup of `session.xml` when one is due, then prunes. The newest backup is the
    /// newest name that is not after the mtime of the file, so a name of a clock fault does not
    /// count. No `session.xml` keeps nothing.
    func keepIfDue(in package: URL) throws(SessionFileError) {
        var info = stat()
        guard stat(package.appending(path: "session.xml").path, &info) == 0 else { return }
        let replacing = Backup(info.st_mtimespec)
        guard isDue(newest: Backup.all(in: package).first { $0 <= replacing }, replacing: replacing) else { return }
        if let kept = try Backup.keep(in: package) { Backup.prune(in: package, keeping: count, after: kept) }
    }
}
