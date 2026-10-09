import DirigibleCore
import Foundation
import Testing

@testable import DirigibleCLI

/// `dirigible backup list` and `dirigible backup revert` (decision 0043, criteria C9, C13, and C16
/// of run 14).
struct BackupCommandTests {
    static let old = "session-20261009T081530.250Z.xml"
    static let middle = "session-20261009T082530.250Z.xml"
    static let new = "session-20261009T083530.250Z.xml"
    let package: TemporaryPackage
    var folder: URL { package.url.appending(path: "Backups") }

    /// Track "a" in `session.xml`. The backup `old` holds an empty session.
    init() throws {
        package = try TemporaryPackage(Session(sampleRate: 48_000))
        let empty = try package.xml()
        try package.edit { try $0.addTrack("a", name: "A", layout: .mono) }
        try plant(Self.old, empty)
    }

    func plant(_ name: String, _ data: Data) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: name))
    }

    /// The bytes of `session.xml` and of each file in `Backups/`, by name.
    func files() throws -> [String: Data] {
        var files = ["session.xml": try package.xml()]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            files["Backups/" + name] = try Data(contentsOf: folder.appending(path: name))
        }
        return files
    }

    @Test func listPrintsTheBackupsNewestFirst() async throws {
        try plant(Self.new, Data("x".utf8))
        try plant(Self.middle, Data("x".utf8))
        try plant("notes.xml", Data("x".utf8))

        let result = try await package.run("backup", "list", "PKG")

        #expect(result == CLIResult(status: 0, stdout: "\(Self.new)\n\(Self.middle)\n\(Self.old)\n", stderr: ""))
    }

    @Test func listOfAPackageWithNoBackupPrintsNothing() async throws {
        try FileManager.default.removeItem(at: folder)

        #expect(try await package.run("backup", "list", "PKG") == CLIResult(status: 0, stdout: "", stderr: ""))

        let missing = try await dirigible("backup", "list", package.folder.appending(path: "Gone.dirigible").path)
        #expect(missing.status == 2 && missing.stderr.contains("cannot read"), "\(missing)")
    }

    @Test func revertRestoresTheBackup() async throws {
        let result = try await package.run("backup", "revert", "PKG", "--name", Self.old)

        #expect(result == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try package.read() == Session(sampleRate: 48_000), "the empty session of the backup")
    }

    /// C9: the state that the revert replaces is a backup.
    @Test func revertKeepsTheReplacedSession() async throws {
        let before = try package.xml()

        #expect(try await package.run("backup", "revert", "PKG", "--name", Self.old).status == 0)

        let added = try files().filter { $0.key != "session.xml" && $0.key != "Backups/" + Self.old }
        #expect(added.count == 1 && added.first?.value == before, "one new backup with the replaced bytes")
    }

    @Test func revertRefusesABadName() async throws {
        let before = try files()

        let result = try await package.run("backup", "revert", "PKG", "--name", "notes.xml")

        #expect(result.status == 64 && result.stderr.contains("backup file name"), "\(result)")
        #expect(try files() == before)
    }

    @Test func revertRefusesAPendingTake() async throws {
        try package.edit {
            try $0.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["a"]))
        }
        let before = try files()

        let result = try await package.run("backup", "revert", "PKG", "--name", Self.old)

        #expect(result.status == 2 && result.stderr.contains("not finalized"), "\(result)")
        #expect(try files() == before)
    }

    /// C13: a newer, a damaged, and a missing backup.
    @Test func revertRefusesANewerBackup() async throws {
        let xml = String(decoding: try package.xml(), as: UTF8.self)
        try #require(xml.contains("version=\"1\""))
        try plant(Self.middle, Data(xml.replacingOccurrences(of: "version=\"1\"", with: "version=\"99\"").utf8))
        try plant(Self.new, Data("xx".utf8))
        let before = try files()
        let reasons = [
            Self.middle: "Backups/\(Self.middle) was made by a newer version",
            Self.new: "Backups/\(Self.new) is not a Dirigible session file",
            "session-20261009T090000.000Z.xml": "cannot read \(package.path)/Backups/session-20261009T090000.000Z.xml",
        ]

        for (name, reason) in reasons {
            let result = try await package.run("backup", "revert", "PKG", "--name", name)
            #expect(result.status == 2 && result.stderr.contains(reason), "\(name): \(result)")
            #expect(try files() == before, "\(name) changes nothing")
        }
    }

    /// A failed copy of the current file refuses the revert and names `Backups`, not the backup.
    @Test func revertNamesAFailedCopy() async throws {
        try #require(chmod(folder.path, 0o555) == 0)
        defer { chmod(folder.path, 0o755) }
        let before = try files()

        let result = try await package.run("backup", "revert", "PKG", "--name", Self.old)

        #expect(result.status == 2 && result.stderr.contains("cannot write \(package.path)/Backups ("), "\(result)")
        #expect(!result.stderr.contains(Self.old), "the text does not blame the backup: \(result)")
        #expect(try files() == before)
    }

    /// A read fault of the copy names `session.xml`.
    @Test func aFailedReadOfTheCopyNamesTheSessionFile() {
        let message = RevertError.currentCopy(.readFailed(errno: EIO)).message(package: "P.dirigible")
        #expect(message.hasPrefix("cannot read P.dirigible/session.xml:"), "\(message)")
    }

    @Test func revertRefusesALockedPackage() async throws {
        let before = try files()

        let result: CLIResult
        do {
            let lock = try PackageLock(package.url)
            defer { withExtendedLifetime(lock) {} }
            result = try await package.run("backup", "revert", "PKG", "--name", Self.old)
        }

        #expect(result == CLIResult(status: 2, stdout: "", stderr: "Error: \(package.path) is open in Dirigible.\n"))
        #expect(try files() == before)
    }
}
