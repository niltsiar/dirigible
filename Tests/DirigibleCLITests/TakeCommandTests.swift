import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// `dirigible take finalize` (criteria 17, 19, and 21 of capture-finalize; criterion 23 of
/// capture-live: the clip IDs of the take, and exit 5 for an armed track with no clip).
struct TakeCommandTests {
    static let takeStart: UInt64 = 1_000_000_000_000
    let package: TemporaryPackage
    var clips: URL { package.url.appending(path: "Clips") }

    /// Tracks `t1` and `t2`, both armed in take 1.
    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.setRecording(
            Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: Self.takeStart, armedTracks: ["t1", "t2"]))
        package = try TemporaryPackage(session)
    }

    /// Writes a closed 2.0 s mono segment for arm `arm` of take 1 with the real writer.
    func segment(arm: Int) throws {
        let capture = package.url.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        let header = CaptureHeader(
            deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelCount: 1, latency: 0, firstSampleTime: 0, firstHostTimeNanos: Self.takeStart)
        let writer = try SegmentWriter(
            folder: capture, name: SegmentName(take: 1, arm: arm, segment: 1), header: header)
        try writer.checkpoint(Checkpoint(fileFrame: 0, sampleTime: 0, hostTimeNanos: Self.takeStart))
        try [Float](repeating: 0.25, count: 96_000).withUnsafeBufferPointer { try writer.write($0, frames: 96_000) }
        try writer.close()
    }

    /// The clip IDs of each track and the recording take, as `info --json` shows them.
    func info() throws -> (clips: [[String]], take: Int?) {
        struct View: Decodable {
            struct Track: Decodable {
                struct Clip: Decodable { let id: String }
                let clips: [Clip]
            }
            struct Recording: Decodable { let take: Int }
            let tracks: [Track]
            let recording: Recording?
        }
        let result = try package.run("info", "PKG", "--json")
        try #require(result.status == 0)
        let view = try JSONDecoder().decode(View.self, from: Data(result.stdout.utf8))
        return (view.tracks.map { $0.clips.map(\.id) }, view.recording?.take)
    }

    static let noClip = "Warning: track \"t2\" has no clip from take 1.\n"

    /// Control of the exit 5 rule: segments for both armed tracks.
    @Test func aRecoverablePackageIsFinalized() throws {
        try segment(arm: 1)
        try segment(arm: 2)
        #expect(try info().take == 1)

        #expect(
            try package.run("take", "finalize", "PKG")
                == CLIResult(status: 0, stdout: "take1-1-1\ntake1-2-1\n", stderr: ""))

        let after = try info()
        #expect(after.clips == [["take1-1-1"], ["take1-2-1"]])
        #expect(after.take == nil)
    }

    /// The recovery of the open finalizes the take; the armed tracks come from `recoveredTake`.
    @Test func anArmedTrackWithNoClipExitsFive() throws {
        try segment(arm: 1)

        #expect(
            try package.run("take", "finalize", "PKG")
                == CLIResult(status: 5, stdout: "take1-1-1\n", stderr: Self.noClip))

        #expect(try info().clips == [["take1-1-1"], []])
    }

    /// The open skips the finalize; the armed tracks come from the pending take before the retry.
    @Test func aPackageWithAMarkerIsRetried() throws {
        try segment(arm: 1)
        let marker = package.url.appending(path: "recovery-attempt")
        FileManager.default.createFile(atPath: marker.path, contents: nil)

        #expect(
            try package.run("take", "finalize", "PKG")
                == CLIResult(status: 5, stdout: "take1-1-1\n", stderr: Self.noClip))

        #expect(try info().clips == [["take1-1-1"], []])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func aFinalizeThatFailsExitsTwoAndKeepsTheTake() throws {
        try segment(arm: 1)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        chmod(clips.path, 0o500)
        defer { chmod(clips.path, 0o755) }

        #expect(
            try package.run("take", "finalize", "PKG")
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: cannot write \(package.path)/Clips/take1-1-1.wav (status -54). "
                        + "The take is still pending.\n"))
        #expect(try info().take == 1)
    }

    @Test func anUnplacedSegmentExitsThreeWithAWarning() throws {
        try segment(arm: 1)
        try segment(arm: 2)
        let handle = try FileHandle(forWritingTo: package.url.appending(path: "Capture/take1-1-1.sidecar"))
        try handle.write(contentsOf: Data("XXXXXXXX".utf8))
        try handle.close()
        let unplaced = "Warning: Capture/take1-1-1.caf is not on the timeline.\n"

        // Exit 3 wins over exit 5, and both lines are written.
        #expect(
            try package.run("take", "finalize", "PKG")
                == CLIResult(
                    status: 3, stdout: "take1-2-1\n",
                    stderr: unplaced + "Warning: track \"t1\" has no clip from take 1.\n"))

        let after = try info()
        #expect(after.clips == [[], ["take1-2-1"]])
        #expect(after.take == nil)
        // No take is pending now, so only the unplaced line stays.
        #expect(try package.run("take", "finalize", "PKG") == CLIResult(status: 3, stdout: "", stderr: unplaced))
    }

    /// Decision 0021 (criterion 19): an unreadable segment keeps the take pending until the user
    /// gives --leave-unreadable; then the take ends without that segment.
    @Test func theLeaveFlagFinishesTheTake() throws {
        try segment(arm: 1)
        try segment(arm: 2)
        let caf = package.url.appending(path: "Capture/take1-1-1.caf")
        chmod(caf.path, 0o000)
        defer { chmod(caf.path, 0o644) }

        #expect(
            try package.run("take", "finalize", "PKG")
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: cannot read \(package.path)/Capture/take1-1-1.caf: Permission denied. "
                        + "The take is still pending. "
                        + "Run it again with --leave-unreadable to finish without that segment.\n"))
        #expect(try info().take == 1)

        #expect(
            try package.run("take", "finalize", "PKG", "--leave-unreadable")
                == CLIResult(
                    status: 3, stdout: "take1-2-1\n",
                    stderr: "Warning: Capture/take1-1-1.caf is not on the timeline.\n"
                        + "Warning: track \"t1\" has no clip from take 1.\n"))
        let after = try info()
        #expect(after.clips == [[], ["take1-2-1"]])
        #expect(after.take == nil)
    }

    @Test func takeFinalizeHasHelp() throws {
        let help = try dirigible("take", "finalize", "--help").stdout
        #expect(help.contains("USAGE: dirigible take finalize <package> [--leave-unreadable]"))
        #expect(help.contains("--leave-unreadable"))
    }
}
