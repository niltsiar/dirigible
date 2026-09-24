import DirigibleCore
import Foundation
import Testing

/// The package lock of decision 0012 (criterion 25). flock refuses a second descriptor in the
/// same process, so these tests need no second process.
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

    @Test func aPackageThatDoesNotExistCannotBeRead() {
        #expect(throws: SessionFileError.readFailed(errno: ENOENT)) {
            try PackageLock(folder.appending(path: "Missing.dirigible"))
        }
        try? FileManager.default.removeItem(at: folder)
    }
}
