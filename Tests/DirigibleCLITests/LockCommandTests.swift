import DirigibleCore
import Foundation
import Testing

/// The edit commands take the package lock (criteria 8 and 26, decision 0012).
struct LockCommandTests {
    let package: TemporaryPackage

    init() throws {
        package = try TemporaryPackage(Session(sampleRate: 48_000))
    }

    @Test func anEditOfALockedPackageExitsTwoAndChangesNothing() throws {
        let before = try package.xml()

        let asError: (SessionFileError) -> any Error = { $0 }
        let locked = try PackageLock.withLock(package.url, locked: asError) {
            try package.run("track", "add", "PKG", "--id", "t1", "--name", "A", "--layout", "mono")
        }

        #expect(locked == CLIResult(status: 2, stdout: "", stderr: "Error: \(package.path) is open in Dirigible.\n"))
        #expect(try package.xml() == before)
        #expect(
            try package.run("track", "add", "PKG", "--id", "t1", "--name", "A", "--layout", "mono")
                == CLIResult(status: 0, stdout: "t1\n", stderr: ""))
    }

    @Test func anEditRemovesALeftoverTemporaryFile() throws {
        let leftover = package.url.appending(path: ".session.xml.\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: leftover.path, contents: Data("x".utf8))

        #expect(try package.run("track", "add", "PKG", "--name", "A", "--layout", "mono").status == 0)

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }
}
