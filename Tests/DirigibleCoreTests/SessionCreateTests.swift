import DirigibleCore
import Foundation
import Testing

/// `Session.create` makes a package only where nothing exists (criterion 10, probes P13 and P15).
struct SessionCreateTests {
    let parent: URL
    var package: URL { parent.appending(path: "Show.dirigible") }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    init() throws {
        parent = FileManager.default.temporaryDirectory.appending(path: "SessionCreateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    @Test func createMakesAnEmptyPackage() throws {
        try Session.create(at: package, sampleRate: 48_000)

        #expect(try Session(contentsOf: package) == Session(sampleRate: 48_000))
        #expect(exists(package.appending(path: "Clips")))
    }

    /// Control: a package or a plain file at the path stays byte-equal.
    @Test(arguments: [true, false]) func createRefusesAPathThatExists(isPackage: Bool) throws {
        let item = isPackage ? package.appending(path: "session.xml") : package
        if isPackage {
            try Session(sampleRate: 44_100).write(to: package)
        } else {
            try Data("x".utf8).write(to: package)
        }
        let before = try Data(contentsOf: item)

        #expect(throws: SessionFileError.exists) { try Session.create(at: package, sampleRate: 48_000) }

        #expect(try Data(contentsOf: item) == before)
    }

    /// Mode 0300: `mkdir` and the first write work, and only the open of the parent for its flush
    /// fails (P13). So the flush runs, and a failure after `mkdir` removes the new folder.
    @Test func createRemovesTheFolderWhenTheParentFlushFails() throws {
        chmod(parent.path, 0o300)
        defer { chmod(parent.path, 0o755) }

        #expect(throws: SessionFileError.writeFailed(step: "flushParent", errno: EACCES)) {
            try Session.create(at: package, sampleRate: 48_000)
        }

        #expect(!exists(package))
    }

    /// An inherit-only deny entry on the parent: `mkdir` works, and the new folder refuses its
    /// `Clips/` folder (P15).
    @Test func createRemovesTheFolderWhenTheFirstWriteFails() throws {
        try acl("+a", "everyone deny add_file,add_subdirectory,directory_inherit,only_inherit")
        defer { try? acl("-N") }

        #expect(throws: SessionFileError.writeFailed(step: "createDirectory", errno: EACCES)) {
            try Session.create(at: package, sampleRate: 48_000)
        }

        #expect(!exists(package))
    }

    /// Runs `/bin/chmod` with `arguments` on the parent folder.
    func acl(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/chmod")
        process.arguments = arguments + [parent.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
}
