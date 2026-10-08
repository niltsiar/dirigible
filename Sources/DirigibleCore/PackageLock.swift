import Foundation

/// An exclusive `flock` on `<package>/.lock`, held for the life of the value (decision 0012).
/// The kernel releases it when the process dies, so a crash leaves no stale lock. The lock file
/// is never deleted.
public final class PackageLock: Sendable {
    /// -1 when the value is unlocked: a volume without flock (ENOTSUP), or a package that no
    /// process of the user can write and that has no lock file (EROFS, EACCES, EPERM).
    private let descriptor: Int32
    /// The package path of the open.
    private let url: URL
    /// The identity of the package, read once at the open (decision 0042): `fstat` of the lock
    /// descriptor, else `stat` of the `.lock` path, else nil (a package with no lock file, which no
    /// process of the user can write).
    public let identity: PackageID?

    /// Throws `.locked` when another holder has the lock, and `.readFailed(ENOENT)` when the
    /// package does not exist. A volume without flock (ENOTSUP) gives an unlocked value
    /// (ponytail: SMB packages keep the 0011 race; fix it when a user needs it). So does a
    /// package without a lock file on a read-only volume (EROFS) or in a folder without write
    /// access (EACCES, EPERM): no process of the user can write the package. With a lock file,
    /// flock works there. The initializer is not public: Swift can release a local value after
    /// its last use, before the save. A scoped caller uses `withLock`; a long holder keeps the
    /// value in a stored property.
    package init(_ package: URL) throws(SessionFileError) {
        url = package
        // Read-only, so an existing lock file opens in a package folder without write access.
        let descriptor = open(package.appending(path: ".lock").path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            let code = errno
            // A lock file without read access in a folder with write access still throws.
            let noWriteAccess = (code == EACCES || code == EPERM) && access(package.path, W_OK) != 0
            if code == EROFS || noWriteAccess {
                self.descriptor = -1
                identity = PackageID(lockFileOf: package)
                return
            }
            throw code == ENOENT ? .readFailed(errno: ENOENT) : .writeFailed(step: "lock", errno: code)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == ENOTSUP {
                self.descriptor = -1
                identity = PackageID(lockFileOf: package)
                return
            }
            throw code == EWOULDBLOCK ? .locked : .writeFailed(step: "flock", errno: code)
        }
        self.descriptor = descriptor
        var info = stat()
        identity = fstat(descriptor, &info) == 0 ? PackageID(info) : PackageID(lockFileOf: package)
    }

    /// Unlocks before the close. flock belongs to the open file, and a child process between
    /// posix_spawn and exec holds a copy of it, so a close alone can leave the lock held.
    deinit {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// The current path of the package that the lock holds (decision 0014, probe P11). A rename or
    /// a move on the same volume moves the lock file with the package, and `F_GETPATH` gives the
    /// new path. After a move to another volume or a delete, `F_GETPATH` gives the old path with
    /// no error, so the path must still hold the locked file: the same device and inode. Else it
    /// throws `.packageMoved`. An unlocked value gives the path of the open.
    public func package() throws(SessionFileError) -> URL {
        guard descriptor >= 0 else { return url }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var locked = stat()
        var there = stat()
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0, fstat(descriptor, &locked) == 0 else {
            throw .packageMoved
        }
        let path = String(cString: &buffer)
        guard stat(path, &there) == 0, there.st_dev == locked.st_dev, there.st_ino == locked.st_ino else {
            throw .packageMoved
        }
        return URL(filePath: path).deletingLastPathComponent()
    }

    /// The free bytes of the volume of the package for a normal process: `fstatfs` on the lock
    /// descriptor, which follows a rename (probe P14). An unlocked value runs `statfs` on the path
    /// of the open. `volumeAvailableCapacityForImportantUsage` also counts purgeable space, which a
    /// write cannot use now. An errno gives 0, so a take stops cleanly.
    public func freeBytes() -> Int64 {
        var info = statfs()
        let status = descriptor >= 0 ? fstatfs(descriptor, &info) : statfs(url.path, &info)
        guard status == 0 else { return 0 }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// Takes the lock, runs `body`, and releases the lock after `body` returns or throws. A lock
    /// error goes through `locked`, and then `body` does not run.
    public static func withLock<Result, Failure: Error>(
        _ package: URL, locked: (SessionFileError) -> Failure, _ body: (PackageLock) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        let lock: PackageLock
        do {
            lock = try PackageLock(package)
        } catch {
            throw locked(error)
        }
        return try withExtendedLifetime(lock) { () throws(Failure) -> Result in try body(lock) }
    }
}

/// The identity of a package: the device and the inode of its `.lock` file (decision 0042). A move
/// or a rename on its volume keeps it; a copy of the package gets another one.
public struct PackageID: Hashable, Sendable {
    private let device: dev_t
    private let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }

    /// The identity of the `.lock` file of `package`, or nil when `stat` finds none.
    public init?(lockFileOf package: URL) {
        var info = stat()
        guard stat(package.appending(path: ".lock").path, &info) == 0 else { return nil }
        self.init(info)
    }

    /// The one compare of two identities: true only for two equal values. A nil never matches, so a
    /// package with no identity counts as another package, and a paste copies its files.
    public static func same(_ a: PackageID?, _ b: PackageID?) -> Bool {
        guard let a, let b else { return false }
        return a == b
    }
}
