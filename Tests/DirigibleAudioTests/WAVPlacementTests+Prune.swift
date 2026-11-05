import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// `Studio.unusedFiles` and `Studio.removeUnusedFiles` after the CAFs of a take are gone
/// (decision 0071, C9): the WAV is the only copy of the take audio, so the prune never moves it as
/// a stray WAV. An unused pool entry of it moves as the files of a free capture do.
extension WAVPlacementTests {
    var backups: URL { url.appending(path: "Backups") }

    func deleteBackups() throws {
        for backup in Backup.all(in: url) {
            try FileManager.default.removeItem(at: backups.appending(path: backup.fileName))
        }
    }

    /// Opens the package, records take 1, removes both CAFs as the sweep does, runs `body`, and
    /// closes the studio, so its lock goes.
    func sweptTake(_ body: (Studio) async throws -> Void) async throws {
        let studio = try await Studio.open(url)
        try await recordAndStop(studio)
        for name in Self.segments {
            try FileManager.default.removeItem(at: capture.appending(path: "\(name.stem).caf"))
        }
        try await body(studio)
        await studio.settle()
    }

    func reopen() async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(TestHAL([]))
        return studio
    }

    /// A revert to the backup before the take leaves both WAVs with no pool entry. After a close
    /// and an open, no undo entry and no backup names them. Fail value: the scan of decision 0047
    /// lists each as a stray WAV.
    @Test func aRevertBeforeTheTakeListsNoUnusedFile() async throws {
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let before = "session-20261009T081530.250Z.xml"
        try Data(contentsOf: url.appending(path: "session.xml")).write(to: backups.appending(path: before))
        try await sweptTake { studio in
            let backup = try #require(Backup.all(in: url).first { $0.fileName == before })
            try await studio.revert(to: backup)
        }
        try deleteBackups()

        let studio = try await reopen()
        let scan = try await studio.unusedFiles()

        #expect(scan.items.isEmpty, "\(scan.items)")
        #expect(scan.kept.count == 0 && scan.kept.bytes == 0)
        #expect(studio.unplacedSegments == Self.segments)
        await studio.settle()
    }

    /// The clip of `take1-1-1` is gone, and after a close and an open no holder names it: the
    /// prune moves its WAV and its sidecar to the Trash (code gate item 3), so the segment is not
    /// unplaced and a ripple can run. Near value: a backup that names the clip keeps the pool
    /// entry, the WAV, and the sidecar.
    @Test(arguments: [false, true]) func aPruneMovesTheFilesOfADeletedTakeClip(held: Bool) async throws {
        let name = Self.segments[0]
        var placed = Data()
        try await sweptTake { studio in
            placed = try Data(contentsOf: url.appending(path: "session.xml"))
            let clip = try #require(studio.session.tracks.flatMap(\.clips).first { $0.id == ClipID(name.stem) })
            try studio.edit(ripple: false) { session throws(SessionError) in try session.removeClips([clip.id]) }
        }
        try deleteBackups()
        if held {
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            try placed.write(to: backups.appending(path: "session-20261009T091530.250Z.xml"))
        }
        let files = [url.appending(path: "Clips/\(name.stem).wav"), capture.appending(path: name.sidecarName)]

        let studio = try await reopen()
        let report = try await studio.removeUnusedFiles(try await studio.unusedFiles())

        let moved = Set(report.moved.map(\.item.path))
        #expect(moved == (held ? [] : ["\(name.stem).wav", "Capture/\(name.sidecarName)"]), "\(report)")
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } == held)
        #expect((studio.session.files[FileID(name.stem)] != nil) == held, "only a holder keeps the pool entry")
        #expect(studio.unplacedSegments.isEmpty)
        #expect(studio.canRipple, "no segment of the take blocks a ripple")
        await RawSweepTests.bounded("the settle does not end") { await studio.settle() }
    }
}
