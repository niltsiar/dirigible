import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// `dirigible file prune` of a take whose CAFs are gone (decision 0071, C9): the WAV is the only
/// copy of the take audio, so the prune never moves it as a stray WAV. An unused pool entry of it
/// that no holder names moves its WAV and its sidecar to the Trash (code gate item 3).
///
/// Fixture: tracks `t1` and `t2`, take 1 at playhead 96,000 with a 2.0 s segment on each arm (the
/// first frame 10 ms after the take start), made with the real writer and ended by
/// `take finalize`. The test then removes each CAF, as the sweep of decision 0071 does. The backup
/// `before` holds the session before the take.
struct SoleCopyPruneCommandTests {
    static let takeStart: UInt64 = 1_000_000_000_000
    static let before = "session-20261009T081530.250Z.xml"
    let package: TemporaryPackage
    var capture: URL { package.url.appending(path: "Capture") }
    var clips: URL { package.url.appending(path: "Clips") }
    var backups: URL { package.url.appending(path: "Backups") }

    init() async throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        package = try TemporaryPackage(session)
        let empty = try package.xml()
        try package.edit {
            try $0.setRecording(
                Recording(
                    take: 1, playheadFrame: 96_000, takeStartHostTimeNanos: Self.takeStart,
                    armedTracks: ["t1", "t2"]))
        }
        for arm in [1, 2] { try segment(arm: arm) }
        try #require(try await package.run("take", "finalize", "PKG").status == 0)
        for stem in ["take1-1-1", "take1-2-1"] {
            try FileManager.default.removeItem(at: capture.appending(path: "\(stem).caf"))
        }
        try plant(Self.before, empty)
    }

    /// Writes a closed 2.0 s mono segment of take 1 for arm `arm` with the real writer.
    func segment(arm: Int) throws {
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        let firstHost = Self.takeStart + 10_000_000
        let header = CaptureHeader(
            deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelCount: 1, latency: 0, firstSampleTime: 0, firstHostTimeNanos: firstHost)
        let writer = try SegmentWriter(
            folder: capture, name: SegmentName(take: 1, arm: arm, segment: 1), header: header)
        try writer.checkpoint(Checkpoint(fileFrame: 0, sampleTime: 0, hostTimeNanos: firstHost))
        let samples = [Float](repeating: 0.25, count: 96_000)
        try samples.withUnsafeBufferPointer { try writer.write($0, frames: 96_000) }
        try writer.close()
    }

    func plant(_ name: String, _ data: Data) throws {
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try data.write(to: backups.appending(path: name))
    }

    /// Deletes each backup but `keep`.
    func deleteBackups(but keep: Set<String>) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: backups.path) where !keep.contains(name) {
            try FileManager.default.removeItem(at: backups.appending(path: name))
        }
    }

    func inode(_ name: String) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: clips.appending(path: name).path)[.systemFileNumber] as? Int
    }

    func starts(_ track: TrackID) throws -> [Frames] {
        try package.read().tracks.first { $0.id == track }?.clips.map(\.start) ?? []
    }

    /// A revert to the backup before the take leaves both WAVs with no pool entry. Fail value: the
    /// scan of decision 0047 lists each as a stray WAV.
    @Test func aRevertBeforeTheTakeListsNoItem() async throws {
        #expect(try await package.run("backup", "revert", "PKG", "--name", Self.before).status == 0)
        try deleteBackups(but: [Self.before])

        let result = try await package.run("file", "prune", "PKG", "--dry-run")

        #expect(
            result
                == CLIResult(
                    status: 0, stdout: "Unused files: 0 (0 bytes)\nKept for a backup: 0 (0 bytes)\n", stderr: ""))
    }

    /// The clip of `take1-1-1` is gone, and no backup names it: the prune drops its pool entry and
    /// moves its WAV and then its sidecar to the Trash, as for a free capture with a CAF. The
    /// segment of `t2` stays.
    @Test func aPruneMovesTheWAVAndSidecarOfADeletedTakeClip() async throws {
        try #require(
            try await package.run("clip", "clear", "PKG", "--track", "t1", "--from", "0", "--to", "1000000").status
                == 0)
        try deleteBackups(but: [])

        let result = try await package.run("file", "prune", "PKG")

        #expect(result.status == 0 && result.stderr == "", "\(result)")
        let moved = result.stdout.split(separator: "\n").compactMap { $0.split(separator: "\t").first }
        #expect(moved.contains("take1-1-1.wav") && moved.contains("Capture/take1-1-1.sidecar"), "\(result)")
        #expect(result.stdout.contains("Moved to the Trash: 2 ("), "\(result)")
        #expect((try? inode("take1-1-1.wav")) == nil, "the WAV is in the Trash")
        #expect(!FileManager.default.fileExists(atPath: capture.appending(path: "take1-1-1.sidecar").path))
        #expect(FileManager.default.fileExists(atPath: capture.appending(path: "take1-2-1.sidecar").path))
        #expect(try package.read().files["take1-1-1"] == nil, "the pool entry is gone")
    }

    /// A backup that names the clip keeps the entry and the WAV, and a revert to that backup
    /// brings the clip back. After the clip goes again and no backup names it, the next prune
    /// moves the WAV to the Trash.
    @Test func aBackupOfTheClipKeepsTheWAV() async throws {
        let placed = try package.xml()
        let clear = ["clip", "clear", "PKG", "--track", "t1", "--from", "0", "--to", "1000000"]
        try #require(try await package.run(clear).status == 0)
        try deleteBackups(but: [])
        let holder = "session-20261009T091530.250Z.xml"
        try plant(holder, placed)
        let bytes = try Data(contentsOf: clips.appending(path: "take1-1-1.wav")).count

        let held = try await package.run("file", "prune", "PKG")

        #expect(held.status == 0 && held.stdout.contains("Kept for a backup: 1 (\(bytes) bytes)"), "\(held)")
        #expect(try package.read().files["take1-1-1"] != nil, "the pool entry stays")
        #expect(try await package.run("backup", "revert", "PKG", "--name", holder).status == 0)
        #expect(try starts("t1") == [96_480])

        try #require(try await package.run(clear).status == 0)
        try deleteBackups(but: [])
        let pruned = try await package.run("file", "prune", "PKG")

        #expect(pruned.stdout.contains("take1-1-1.wav\t"), "\(pruned)")
        #expect((try? inode("take1-1-1.wav")) == nil, "the WAV moves after the backup goes")
    }

    /// C21 (f) (decision 0072): an unarchive kept the FLAC of the deleted clip as damaged, so the
    /// package has no `archive` attribute. The dry run lists the entry by its pool path with the
    /// bytes of the FLAC, and the prune moves the FLAC, then the sidecar, to the Trash.
    @Test func aPruneMovesTheKeptFLACOfADeletedTakeClip() async throws {
        try #require(
            try await package.run("clip", "clear", "PKG", "--track", "t1", "--from", "0", "--to", "1000000").status
                == 0)
        try deleteBackups(but: [])
        let file = try #require(try package.read().files["take1-1-1"])
        try #require(try archiveClip(file, in: package.url, rate: 48_000))
        let flac = clips.appending(path: "take1-1-1.flac")
        let whole = try Data(contentsOf: flac)
        try whole.prefix(whole.count / 2).write(to: flac)
        let damaged = try Data(contentsOf: flac)

        let listed = try await package.run("file", "prune", "PKG", "--dry-run")
        #expect(listed.stdout.contains("take1-1-1.wav\t\(damaged.count) bytes\n"), "\(listed)")
        #expect(try Data(contentsOf: flac) == damaged, "the dry run changes no file")

        let result = try await package.run("file", "prune", "PKG")

        #expect(result.status == 0 && result.stderr == "", "\(result)")
        let moved = result.stdout.split(separator: "\n").compactMap { $0.split(separator: "\t").first }
        #expect(moved.contains("take1-1-1.wav") && moved.contains("Capture/take1-1-1.sidecar"), "\(result)")
        #expect((try? inode("take1-1-1.flac")) == nil, "the FLAC is in the Trash")
        #expect(!FileManager.default.fileExists(atPath: capture.appending(path: "take1-1-1.sidecar").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted() == ["take1-2-1.wav"])
        #expect(try package.read().files["take1-1-1"] == nil, "the pool entry is gone")
    }
}
