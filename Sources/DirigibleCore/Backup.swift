import Foundation

/// The folder of the backups in a package (decision 0043).
package let backupsFolderName = "Backups"

/// One backup of `session.xml` in `Backups/` (decision 0043). The value is a name, not a path:
/// each call gets the package path from its caller, so a rename of the package changes nothing.
public struct Backup: Hashable, Comparable, Sendable {
    /// The time of the copied `session.xml`, in milliseconds since 1970. An integer, so a name
    /// and a compare never round.
    var milliseconds: Int64

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

    /// The revert source: reads this backup in the package that `lock` holds, and refuses it as
    /// `Session(contentsOf:)` refuses a `session.xml` (a newer version, a damaged file, a missing
    /// file). Then it keeps a copy of the current `session.xml`, with no due check and no prune,
    /// so the state that the revert replaces stays on the disk. A failed copy refuses the revert
    /// (decision 0043). Apply the result with `Session.reverted(to:)`.
    public func readForRevert(under lock: PackageLock) throws(RevertReadError) -> Session {
        let package: URL
        let target: Session
        do throws(SessionFileError) {
            package = try lock.package()
            let data: Data
            do {
                data = try Data(contentsOf: Backup.folder(of: package).appending(path: fileName))
            } catch {
                throw .readFailed(errno: posixCode(of: error))
            }
            target = try Session(xml: data)
        } catch {
            throw .backup(error)
        }
        do throws(SessionFileError) {
            _ = try Backup.keep(in: package, forRevert: true)
        } catch {
            throw .currentCopy(error)
        }
        return target
    }

    static func folder(of package: URL) -> URL { package.appending(path: backupsFolderName) }

    /// Copies `session.xml` of `package` to `Backups/<name of its mtime>` with the durable write
    /// of a save. When a backup has that name, the name gets 1 ms more until it is free. Returns
    /// nil and copies nothing when a backup has the same bytes, so the caller prunes only after a
    /// new copy. With `forRevert`, only the backups that the next prune keeps count, so the state
    /// that a revert replaces stays at least past that prune. Only a lock holder calls it.
    static func keep(in package: URL, forRevert: Bool = false) throws(SessionFileError) -> Backup? {
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
        let held = all(in: package).prefix(forRevert ? BackupPolicy.count - 1 : Int.max)
        if held.contains(where: { holds(folder.appending(path: $0.fileName), data) }) { return nil }
        var backup = Backup(info.st_mtimespec)
        // A coarse mtime (HFS+ 1 s, exFAT 10 ms) gives two states one name. A file with the name
        // has other bytes, cannot be read, or (for a revert) is past the 19 newest, so the copy
        // takes the next free millisecond and never replaces it.
        while access(folder.appending(path: backup.fileName).path, F_OK) == 0 { backup.milliseconds += 1 }
        try replaceDurably(folder.appending(path: backup.fileName), with: data)
        return backup
    }

    /// Deletes each backup after the `count` newest. It counts only the names that are not after
    /// `newest`, so names of a clock fault never push the new backup out. It never deletes a name
    /// that does not parse (decision 0024 P10), a backup of a newer version (0024 P4), or a
    /// backup that it cannot read, which can be of a newer version.
    static func prune(in package: URL, keeping count: Int, after newest: Backup) {
        let folder = folder(of: package)
        for old in all(in: package).filter({ $0 <= newest }).dropFirst(count) {
            let url = folder.appending(path: old.fileName)
            guard let data = try? Data(contentsOf: url), !isNewer(data) else { continue }
            unlink(url.path)
        }
    }

    /// The backup at the close of a session window (decision 0043): `keep(in:)` with no due
    /// check, then the prune after a new copy. A fault keeps nothing and never throws.
    package static func keepAtClose(in package: URL) {
        if let kept = try? keep(in: package) { prune(in: package, keeping: BackupPolicy.count, after: kept) }
    }

    /// True when the file at `url` has the bytes of `data`. It reads only a file of the same
    /// size, so the byte check reads few backups in full.
    private static func holds(_ url: URL, _ data: Data) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && info.st_size == off_t(data.count) && (try? Data(contentsOf: url)) == data
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

/// Why `Backup.readForRevert(under:)` refused a revert. Nothing changed.
public enum RevertReadError: Error, Hashable, Sendable {
    /// The backup cannot be read, is damaged, or is of a newer version, or the package moved.
    case backup(SessionFileError)
    /// The copy of the current `session.xml` failed: `.readFailed` is a read of `session.xml`,
    /// another case is a write in `Backups/`.
    case currentCopy(SessionFileError)
}

/// When a lock-holder save keeps a backup, and how many stay (decision 0043).
package enum BackupPolicy: Sendable {
    /// A backup when one is due, then the prune.
    case standard
    /// No backup step: the take-start save, between Record and the device attach (decision 0043).
    case none

    /// Milliseconds from the newest backup to the replaced file (600 s).
    static let interval: Int64 = 600_000
    /// The backups that a prune keeps.
    static let count = 20

    /// True when no backup is given, or when `replacing` is `interval` or more after `newest`.
    /// Both are file times, so one clock decides.
    static func isDue(newest: Backup?, replacing: Backup) -> Bool {
        guard let newest else { return true }
        return replacing.milliseconds - newest.milliseconds >= interval
    }

    /// Keeps a backup of `session.xml` when one is due, then prunes. The newest backup is the
    /// newest name that is not after the mtime of the file, so a name of a clock fault does not
    /// count. No `session.xml` keeps nothing. With less than twice the size of `session.xml`
    /// free, it keeps nothing: the copy must not take the space that the save needs.
    func keepIfDue(in package: URL, freeBytes: (URL) -> Int64 = backupFreeBytes) throws(SessionFileError) {
        guard self != .none else { return }
        var info = stat()
        guard stat(package.appending(path: "session.xml").path, &info) == 0 else { return }
        let replacing = Backup(info.st_mtimespec)
        guard Self.isDue(newest: Backup.all(in: package).first { $0 <= replacing }, replacing: replacing) else {
            return
        }
        guard freeBytes(package) >= 2 * Int64(info.st_size) else { return }
        if let kept = try Backup.keep(in: package) { Backup.prune(in: package, keeping: Self.count, after: kept) }
    }
}

/// The free bytes for the space check of a backup. An error gives `Int64.max`, so a volume that
/// `statfs` cannot read still gets backups: the save catches a failed copy.
func backupFreeBytes(_ url: URL) -> Int64 { volumeFreeBytes(descriptor: -1, path: url.path) ?? .max }
