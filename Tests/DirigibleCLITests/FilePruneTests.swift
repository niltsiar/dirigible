import DirigibleCore
import Foundation
import Testing

/// `dirigible file prune` (decision 0047, criteria C5, C10, and C11 of run
/// `2026-10-12-remove-unused-files`). Each file has a UUID name. The test that moves files to the
/// real Trash removes only the exact URLs that the CLI prints; it never searches the Trash by name.
struct FilePruneTests {
    let package: TemporaryPackage
    let unused = "unused-\(UUID().uuidString).wav"
    let stray = "stray-\(UUID().uuidString).wav"
    var clips: URL { package.url.appending(path: "Clips") }

    /// Track "a" with clip "c" of file "used"; file "spare" has no clip; a stray WAV.
    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("a", name: "A", layout: .mono)
        try session.addFile(AudioFile(id: "used", path: "used.wav", layout: .mono, length: 48_000))
        try session.addFile(AudioFile(id: "spare", path: unused, layout: .mono, length: 48_000))
        try session.place(Clip(id: "c", file: "used", start: 0, offset: 0, length: 1_000), on: "a")
        package = try TemporaryPackage(session)
        for (name, bytes) in [("used.wav", 3), (unused, 5), (stray, 7)] {
            try Data(count: bytes).write(to: clips.appending(path: name))
        }
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: clips.appending(path: name).path) }

    func backupNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: "Backups").path)) ?? []
    }

    /// The bytes and the modification time of `session.xml`.
    func sessionState() throws -> (Data, Date?) {
        let attributes = try FileManager.default.attributesOfItem(atPath: package.sessionXML.path)
        return (try package.xml(), attributes[.modificationDate] as? Date)
    }

    /// C10.
    @Test func dryRunWritesNothing() async throws {
        let (bytes, time) = try sessionState()
        let backups = backupNames()

        let result = try await package.run("file", "prune", "PKG", "--dry-run")

        let expected = [unused, stray].sorted().map { "\($0)\t\($0 == unused ? 5 : 7) bytes" }
        #expect(
            result
                == CLIResult(
                    status: 0,
                    stdout: (expected + ["Unused files: 2 (12 bytes)", "Kept for a backup: 0 (0 bytes)"])
                        .joined(separator: "\n") + "\n", stderr: ""))
        let (bytesAfter, timeAfter) = try sessionState()
        #expect(bytesAfter == bytes && timeAfter == time, "session.xml did not change")
        #expect(backupNames() == backups)
        #expect(exists(unused) && exists(stray) && exists("used.wav"))
    }

    /// C9 and C11 with the real Trash.
    @Test func prunesAndReports() async throws {
        let result = try await package.run("file", "prune", "PKG")

        let lines = result.stdout.split(separator: "\n").map(String.init)
        let moved = lines.map { $0.split(separator: "\t").map(String.init) }.filter { $0.count == 3 }
        let trashed = moved.map { URL(filePath: $0[2]) }
        defer { for url in trashed { try? FileManager.default.removeItem(at: url) } }
        #expect(result.status == 0 && result.stderr == "", "\(result)")
        #expect(moved.map(\.[0]) == [unused, stray].sorted())
        #expect(trashed.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "each file is in the Trash")
        #expect(trashed.allSatisfy { $0.path.contains("/.Trash") }, "\(trashed)")
        #expect(lines.contains("Moved to the Trash: 2 (12 bytes). The space comes back when you empty the Trash."))
        #expect(!exists(unused) && !exists(stray) && exists("used.wav"))
        let saved = try package.read()
        #expect(saved.files["spare"] == nil && saved.files["used"] != nil)
    }

    /// C11: a pending take exits 2 with the text of every edit and moves nothing.
    @Test func pendingTakeRefused() async throws {
        try package.edit {
            try $0.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: []))
        }
        let before = try package.xml()

        let result = try await package.run("file", "prune", "PKG")

        #expect(
            result
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: \(package.path) has a take that is not finalized; open it in Dirigible first.\n"))
        #expect(try package.xml() == before && exists(unused) && exists(stray))
    }

    /// C11: the app has the package open.
    @Test func lockedPackageRefused() async throws {
        let before = try package.xml()
        let result: CLIResult
        do {
            let lock = try PackageLock(package.url)
            defer { withExtendedLifetime(lock) {} }
            result = try await package.run("file", "prune", "PKG")
        }

        #expect(result == CLIResult(status: 2, stdout: "", stderr: "Error: \(package.path) is open in Dirigible.\n"))
        #expect(try package.xml() == before && exists(unused) && exists(stray))
    }

    /// C5: a backup of a newer version blocks the scan; nothing moves.
    @Test func newerBackupExits1() async throws {
        let xml = String(decoding: try package.xml(), as: UTF8.self)
            .replacing(/version="\d+"/, with: "version=\"99\"")
        let name = "session-20330518T033320.000Z.xml"
        let backups = package.url.appending(path: "Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try Data(xml.utf8).write(to: backups.appending(path: name))
        let before = try package.xml()

        let result = try await package.run("file", "prune", "PKG")

        #expect(result.status == 1 && result.stdout == "", "\(result)")
        #expect(result.stderr.contains("\(package.path)/Backups/\(name) was made by a newer version"), "\(result)")
        #expect(result.stderr.contains("no file moves until that backup goes"), "\(result)")
        #expect(try package.xml() == before && exists(unused) && exists(stray))
    }
}
