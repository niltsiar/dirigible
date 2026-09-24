import Foundation

/// An exclusive `flock` on `<package>/.lock`, held for the life of the value (decision 0012).
/// The kernel releases it when the process dies, so a crash leaves no stale lock. The lock file
/// is never deleted.
public final class PackageLock: Sendable {
    /// -1 when the value is unlocked: a volume without flock (ENOTSUP), or a read-only volume
    /// without a lock file (EROFS).
    private let descriptor: Int32

    /// Throws `.locked` when another holder has the lock, and `.readFailed(ENOENT)` when the
    /// package does not exist. A volume without flock (ENOTSUP) gives an unlocked value
    /// (ponytail: SMB packages keep the 0011 race; fix it when a user needs it). So does a
    /// read-only volume without a lock file (EROFS), where no process can write the package; with
    /// a lock file, flock works there. The initializer
    /// is not public: Swift can release a local value after its last use, before the save. A
    /// scoped caller uses `withLock`; a long holder keeps the value in a stored property.
    package init(_ package: URL) throws(SessionFileError) {
        // Read-only, so an existing lock file opens in a package folder without write access.
        let descriptor = open(package.appending(path: ".lock").path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            let code = errno
            if code == EROFS {
                self.descriptor = -1
                return
            }
            throw code == ENOENT ? .readFailed(errno: ENOENT) : .writeFailed(step: "lock", errno: code)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == ENOTSUP {
                self.descriptor = -1
                return
            }
            throw code == EWOULDBLOCK ? .locked : .writeFailed(step: "flock", errno: code)
        }
        self.descriptor = descriptor
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// Takes the lock, runs `body`, and releases the lock after `body` returns or throws. A lock
    /// error goes through `locked`, and then `body` does not run.
    public static func withLock<Result, Failure: Error>(
        _ package: URL, locked: (SessionFileError) -> Failure, _ body: () throws(Failure) -> Result
    ) throws(Failure) -> Result {
        let lock: PackageLock
        do {
            lock = try PackageLock(package)
        } catch {
            throw locked(error)
        }
        return try withExtendedLifetime(lock) { () throws(Failure) -> Result in try body() }
    }
}
