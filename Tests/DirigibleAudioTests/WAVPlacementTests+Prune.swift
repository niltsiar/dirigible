import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// `Studio.unusedFiles` and `Studio.removeUnusedFiles` after the CAFs of a take are gone
/// (decision 0071, C9): the WAV is the only copy of the take audio, so the prune never moves it.
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
    /// prune drops its pool entry, keeps the WAV, and the segment places at its recorded frame.
    @Test func aPruneKeepsTheWAVOfADeletedTakeClip() async throws {
        let name = Self.segments[0]
        var recorded: Clip?
        try await sweptTake { studio in
            let clip = try #require(studio.session.tracks.flatMap(\.clips).first { $0.id == ClipID(name.stem) })
            try studio.edit(ripple: false) { session throws(SessionError) in try session.removeClips([clip.id]) }
            recorded = clip
        }
        try deleteBackups()
        let wav = try wavFacts(name)

        let studio = try await reopen()
        let report = try await studio.removeUnusedFiles(try await studio.unusedFiles())

        #expect(report.unplaced.map(\.path) == ["\(name.stem).wav"] && report.moved.isEmpty, "\(report)")
        #expect(studio.session.files[FileID(name.stem)] == nil, "the pool entry is gone")
        #expect(studio.unplacedSegments == [name])
        _ = try await studio.place(name)
        let placed = studio.session.tracks.flatMap(\.clips).first { $0.id == ClipID(name.stem) }
        #expect(placed?.start != nil && placed?.start == recorded?.start)
        let after = try wavFacts(name)
        #expect(after.inode == wav.inode && after.bytes == wav.bytes, "the WAV stays")
        await studio.settle()
    }
}
