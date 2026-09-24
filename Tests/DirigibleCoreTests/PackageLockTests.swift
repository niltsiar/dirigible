import DirigibleCore
import Foundation
import Testing

/// The package lock of decision 0012 (criterion 25). flock refuses a second descriptor in the
/// same process, so only the child-process test needs a second process.
struct PackageLockTests {
    let folder: URL
    var package: URL { folder.appending(path: "Show.dirigible") }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "PackageLockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder.appending(path: "Show.dirigible"), withIntermediateDirectories: true)
    }

    struct Mapped: Error, Equatable { let error: SessionFileError }

    @Test func aSecondLockThrowsUntilTheFirstIsReleased() throws {
        var first: PackageLock? = try PackageLock(package)
        #expect(throws: SessionFileError.locked) { try PackageLock(package) }
        #expect(first != nil)
        first = nil
        #expect(throws: Never.self) { try PackageLock(package) }
        #expect(FileManager.default.fileExists(atPath: package.appending(path: ".lock").path))
        try? FileManager.default.removeItem(at: folder)
    }

    /// A child process can hold a copy of the lock descriptor: posix_spawn copies every
    /// descriptor and closes the O_CLOEXEC ones only at exec. The release must not wait for the
    /// child. Without an explicit unlock, a parallel test that spawns a process made the other
    /// tests of this suite fail with `.locked` (3 in 15 runs of `make test`).
    @Test func aReleaseDoesNotWaitForAChildWithACopyOfTheDescriptor() throws {
        var first: PackageLock? = try PackageLock(package)
        let child = try spawnSleepWithACopy(of: package.appending(path: ".lock"))
        defer {
            kill(child, SIGKILL)
            waitpid(child, nil, 0)
            try? FileManager.default.removeItem(at: folder)
        }
        #expect(first != nil)
        first = nil
        #expect(throws: Never.self) { try PackageLock(package) }
    }

    /// Starts `/bin/sleep` with a copy of the descriptor that this process holds on `file`.
    func spawnSleepWithACopy(of file: URL) throws -> pid_t {
        var target = stat()
        try #require(stat(file.path, &target) == 0)
        let descriptor = try #require(
            (0..<getdtablesize()).first { candidate in
                var info = stat()
                return fstat(candidate, &info) == 0 && info.st_dev == target.st_dev && info.st_ino == target.st_ino
            })
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // dup2 to another number clears O_CLOEXEC, so the copy stays open after exec.
        posix_spawn_file_actions_adddup2(&actions, descriptor, descriptor == 3 ? 4 : 3)
        let words: [String] = ["/bin/sleep", "60"]
        let argv = words.map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var child: pid_t = 0
        try #require(posix_spawn(&child, "/bin/sleep", &actions, nil, argv, environ) == 0)
        return child
    }

    @Test func withLockHoldsTheLockForTheBodyOnly() throws {
        let result = try PackageLock.withLock(package, locked: Mapped.init) { () throws(Mapped) -> Int in
            #expect(throws: SessionFileError.locked) { try PackageLock(package) }
            return 7
        }
        #expect(result == 7)
        #expect(throws: Never.self) { try PackageLock(package) }

        #expect(throws: Mapped(error: .invalidValue(element: "x", attribute: "y"))) {
            try PackageLock.withLock(package, locked: Mapped.init) { () throws(Mapped) in
                throw Mapped(error: .invalidValue(element: "x", attribute: "y"))
            }
        }
        #expect(throws: Never.self) { try PackageLock(package) }
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func aHeldLockMapsTheErrorAndDoesNotRunTheBody() throws {
        let held = try PackageLock(package)
        var ran = false
        #expect(throws: Mapped(error: .locked)) {
            try PackageLock.withLock(package, locked: Mapped.init) { () throws(Mapped) in ran = true }
        }
        #expect(!ran)
        withExtendedLifetime(held) {}
        try? FileManager.default.removeItem(at: folder)
    }

    enum NoWriteAccess: String, CaseIterable, CustomTestStringConvertible {
        /// Mode 0555: open gives EACCES.
        case readOnlyMode
        /// The user immutable flag: open gives EPERM.
        case immutableFlag
        var testDescription: String { rawValue }
    }

    /// Decision 0012: a package folder without write access and without a `.lock` file opens
    /// without a lock, like a read-only volume. No process of the user can write the package.
    @Test(arguments: NoWriteAccess.allCases)
    func aPackageWithoutWriteAccessOpensUnlocked(access: NoWriteAccess) throws {
        switch access {
        case .readOnlyMode: chmod(package.path, 0o555)
        case .immutableFlag: chflags(package.path, UInt32(UF_IMMUTABLE))
        }
        defer {
            chflags(package.path, 0)
            chmod(package.path, 0o755)
            try? FileManager.default.removeItem(at: folder)
        }

        let first = try PackageLock(package)
        #expect(throws: Never.self) { try PackageLock(package) }
        #expect(!FileManager.default.fileExists(atPath: package.appending(path: ".lock").path))
        withExtendedLifetime(first) {}
    }

    /// Only the folder decides: a writable package can still get a save, so it keeps the lock.
    @Test func aLockFileWithoutReadAccessInAWritablePackageThrows() throws {
        let lock = package.appending(path: ".lock")
        FileManager.default.createFile(atPath: lock.path, contents: nil)
        chmod(lock.path, 0o000)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(throws: SessionFileError.writeFailed(step: "lock", errno: EACCES)) { try PackageLock(package) }
    }

    @Test func aPackageThatDoesNotExistCannotBeRead() {
        #expect(throws: SessionFileError.readFailed(errno: ENOENT)) {
            try PackageLock(folder.appending(path: "Missing.dirigible"))
        }
        try? FileManager.default.removeItem(at: folder)
    }
}
