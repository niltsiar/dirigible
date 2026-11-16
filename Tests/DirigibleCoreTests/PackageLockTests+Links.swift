import Foundation
import Testing

@testable import DirigibleCore

extension PackageLockTests {
    /// The kinds of `.lock` that are not one regular file.
    enum LockKind: CaseIterable {
        case linkToAFile, linkToAMissingPath, hardLink, folder, fifo
    }

    /// C10. A link can name the lock of another package, and a hard link makes `F_GETPATH` name it,
    /// so a save could replace the session of that package (decision 0012). The open makes no file
    /// at the target of a link.
    @Test(arguments: LockKind.allCases)
    func eachLockThatIsNotOneRegularFileIsRefused(_ kind: LockKind) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let lock = package.appending(path: ".lock")
        let target = folder.appending(path: "Other.lock")
        switch kind {
        case .linkToAFile:
            try Data().write(to: target)
            try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
        case .linkToAMissingPath:
            try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
        case .hardLink:
            try Data().write(to: target)
            try #require(link(target.path, lock.path) == 0)
        case .folder:
            try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        case .fifo:
            try #require(mkfifo(lock.path, 0o644) == 0)
        }

        #expect(throws: SessionFileError.unsafeItem(".lock")) { try PackageLock(package) }
        if kind == .linkToAMissingPath { #expect(!FileManager.default.fileExists(atPath: target.path)) }
    }
}
