import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCLI

/// `dirigible capture place` (decision 0021, criteria 17, 18, 20, and the CLI part of 29).
///
/// Fixture: tracks `t1` and `t2`, take 1 at playhead 96,000 with a 2.0 s segment on each arm (the
/// first frame 10 ms after the take start, latency 0), made with the real writer. `take finalize`
/// ends the take and writes its anchor; then `clip clear` and `file remove` take the clip and
/// the pool file of `take1-1-1` away. Its recorded start is 96,000 + 480 = 96,480.
struct PlaceCommandTests {
    static let takeStart: UInt64 = 1_000_000_000_000
    let package: TemporaryPackage
    var capture: URL { package.url.appending(path: "Capture") }
    var clips: URL { package.url.appending(path: "Clips") }

    init() async throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.setRecording(
            Recording(
                take: 1, playheadFrame: 96_000, takeStartHostTimeNanos: Self.takeStart, armedTracks: ["t1", "t2"]))
        package = try TemporaryPackage(session)
        try segment(arm: 1)
        try segment(arm: 2)
        try #require(try await package.run("take", "finalize", "PKG").status == 0)
        try #require(
            try await package.run("clip", "clear", "PKG", "--track", "t1", "--from", "0", "--to", "1000000").status == 0
        )
        try #require(try await package.run("file", "remove", "PKG", "take1-1-1").status == 0)
    }

    /// Writes a closed 2.0 s segment of take `take` for arm `arm` with the real writer.
    func segment(take: Int = 1, arm: Int, channels: Int = 1, firstHost: UInt64 = takeStart + 10_000_000) throws {
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        let header = CaptureHeader(
            deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelCount: channels, latency: 0, firstSampleTime: 0, firstHostTimeNanos: firstHost)
        let writer = try SegmentWriter(
            folder: capture, name: SegmentName(take: take, arm: arm, segment: 1), header: header)
        try writer.checkpoint(Checkpoint(fileFrame: 0, sampleTime: 0, hostTimeNanos: firstHost))
        let samples = [Float](repeating: 0.25, count: 96_000 * channels)
        try samples.withUnsafeBufferPointer { try writer.write($0, frames: 96_000) }
        try writer.close()
    }

    /// The bytes of each file in `Clips/`.
    func clipBytes() throws -> [String: Data] {
        try Dictionary(
            uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: clips.path).map {
                ($0, try Data(contentsOf: clips.appending(path: $0)))
            })
    }

    /// The start of each clip of `track`, by clip ID, as `info --json` shows them.
    func starts(_ track: String) async throws -> [String: Int] {
        struct View: Decodable {
            struct Track: Decodable {
                struct Clip: Decodable {
                    let id: String
                    let start: Int
                }
                let id: String
                let clips: [Clip]
            }
            let tracks: [Track]
        }
        let result = try await package.run("info", "PKG", "--json")
        try #require(result.status == 0)
        let view = try JSONDecoder().decode(View.self, from: Data(result.stdout.utf8))
        let clips = view.tracks.first { $0.id == track }?.clips ?? []
        return Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0.start) })
    }

    // MARK: Criterion 17

    @Test func aPlacementAtTheRecordedTimeWritesTheClipID() async throws {
        #expect(
            try await package.run("capture", "place", "PKG", "take1-1-1")
                == CLIResult(status: 0, stdout: "take1-1-1\n", stderr: ""))

        #expect(try await starts("t1") == ["take1-1-1": 96_480])
    }

    /// A segment that ends before the take playhead becomes a pool file with no clip (decision
    /// 0004 **Timing**). Stdout is a clip ID or nothing, so the reason goes to stderr.
    @Test func aSegmentBeforeTheFloorPlacesNoClip() async throws {
        // The new first frame needs a new capture: the fixture keeps the capture of the old one.
        try package.edit { try $0.removeCapture("take1-1-1") }
        try segment(arm: 1, firstHost: Self.takeStart - 5_000_000_000)

        let result = try await package.run("capture", "place", "PKG", "take1-1-1")

        #expect(
            result
                == CLIResult(
                    status: 0, stdout: "", stderr: "Warning: no clip: the segment ends before the take playhead\n"),
            "\(result)")
        #expect(try await starts("t1") == [:])
        #expect(try Session(contentsOf: package.url).files["take1-1-1"]?.capture == "take1-1-1")
    }

    /// Frame 0 is the lowest start (the control of the `--at` check).
    @Test(arguments: [0, 1_000])
    func anExplicitTrackAndStartReplaceTheAnchor(at: Int) async throws {
        #expect(
            try await package.run("capture", "place", "PKG", "take1-1-1", "--track", "t2", "--at", "\(at)")
                == CLIResult(status: 0, stdout: "take1-1-1\n", stderr: ""))

        // The placed clip goes on top, so it can trim take1-2-1 (decision 0021 Q5).
        #expect(try await starts("t2")["take1-1-1"] == at)
        #expect(try await starts("t1") == [:])
    }

    // MARK: Criterion 18

    enum Refusal: String, CaseIterable, CustomTestStringConvertible {
        case placed, noCAF, missingSidecar, emptyCAF, noAnchor, noAnchorWithTrack, wavInUse
        case layoutMismatch, newerSidecar, newerAnchor
        var testDescription: String { rawValue }
    }

    /// Changes the package for `refusal` and returns the arguments after the package and the
    /// error line.
    func prepare(_ refusal: Refusal) throws -> (arguments: [String], stderr: String) {
        let anchor = capture.appending(path: "take1.anchor")
        let notUnplaced = { (stem: String) in
            "Error: \(stem) is on the timeline, is in a pending take, or has no audio in Capture/.\n"
        }
        let noAlignment = "Error: no take anchor gives the track and the start of take1-1-1. Give --track and --at.\n"
        switch refusal {
        case .placed:
            return (["take1-2-1"], notUnplaced("take1-2-1"))
        case .noCAF:
            return (["take1-1-9"], notUnplaced("take1-1-9"))
        case .missingSidecar:
            try FileManager.default.removeItem(at: capture.appending(path: "take1-1-1.sidecar"))
            return (
                ["take1-1-1"],
                "Error: Capture/take1-1-1.sidecar is missing or damaged, so the timing of take1-1-1 is not known.\n"
            )
        case .emptyCAF:
            try Data().write(to: capture.appending(path: "take1-1-1.caf"))
            return (["take1-1-1"], "Error: Capture/take1-1-1.caf is not audio that Dirigible can convert.\n")
        case .noAnchor:
            try FileManager.default.removeItem(at: anchor)
            return (["take1-1-1"], noAlignment)
        case .noAnchorWithTrack:
            try FileManager.default.removeItem(at: anchor)
            return (["take1-1-1", "--track", "t1"], noAlignment)
        case .wavInUse:
            try package.edit { try $0.addFile(AudioFile(id: "user", path: "take1-1-1.wav", layout: .mono, length: 1)) }
            return (["take1-1-1"], "Error: file \"user\" has the path of Clips/take1-1-1.wav.\n")
        case .layoutMismatch:
            try segment(arm: 1, channels: 2)
            return (["take1-1-1"], "Error: file \"take1-1-1\" does not have the layout of track \"t1\".\n")
        case .newerSidecar:
            try setMagicDigit(capture.appending(path: "take1-1-1.sidecar"), "2")
            return (
                ["take1-1-1", "--track", "t1", "--at", "0"],
                "Error: Capture/take1-1-1.sidecar was made by a newer version of Dirigible (version 2), so this build "
                    + "cannot place take1-1-1.\n"
            )
        case .newerAnchor:
            try setMagicDigit(anchor, "3")
            return (
                ["take1-1-1"],
                "Error: Capture/take1.anchor was made by a newer version of Dirigible (version 3). Give --track and "
                    + "--at to place take1-1-1.\n"
            )
        }
    }

    @Test(arguments: Refusal.allCases)
    func aRefusedPlacementExitsOneAndChangesNothing(refusal: Refusal) async throws {
        let (arguments, stderr) = try prepare(refusal)
        let (before, files) = (try package.xml(), try clipBytes())

        #expect(
            try await package.run(["capture", "place", "PKG"] + arguments)
                == CLIResult(status: 1, stdout: "", stderr: stderr)
        )

        #expect(try package.xml() == before)
        #expect(try clipBytes() == files)
    }

    /// Decision 0024: with --track and --at, a newer anchor is not read and keeps its bytes.
    @Test func aNewerAnchorDoesNotRefuseAnExplicitPlacement() async throws {
        let anchor = capture.appending(path: "take1.anchor")
        try setMagicDigit(anchor, "3")
        let bytes = try Data(contentsOf: anchor)

        #expect(
            try await package.run("capture", "place", "PKG", "take1-1-1", "--track", "t1", "--at", "0")
                == CLIResult(status: 0, stdout: "take1-1-1\n", stderr: ""))

        #expect(try await starts("t1") == ["take1-1-1": 0])
        #expect(try Data(contentsOf: anchor) == bytes)
    }

    /// No recovery runs as a side effect (decision 0021 Q6): no marker, and no WAV of take 2.
    @Test func aPendingTakeExitsTwo() async throws {
        try segment(take: 2, arm: 1)
        try package.edit {
            try $0.setRecording(
                Recording(take: 2, playheadFrame: 0, takeStartHostTimeNanos: Self.takeStart, armedTracks: ["t1"]))
        }
        let (before, files) = (try package.xml(), try FileManager.default.contentsOfDirectory(atPath: clips.path))

        #expect(
            try await package.run("capture", "place", "PKG", "take1-1-1")
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: \(package.path) has a take that is not finalized; open it in Dirigible first.\n"))

        #expect(try package.xml() == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: clips.path) == files)
        #expect(!FileManager.default.fileExists(atPath: package.url.appending(path: "recovery-attempt").path))
    }

    @Test func aLockedPackageExitsTwo() async throws {
        let before = try package.xml()

        let locked: CLIResult
        do {
            let lock = try PackageLock(package.url)
            defer { withExtendedLifetime(lock) {} }
            locked = try await package.run("capture", "place", "PKG", "take1-1-1")
        }

        #expect(locked == CLIResult(status: 2, stdout: "", stderr: "Error: \(package.path) is open in Dirigible.\n"))
        #expect(try package.xml() == before)
    }

    /// Criterion 29: an I/O error on the anchor is a fault that can go away, not "no anchor".
    @Test func anUnreadableAnchorExitsTwo() async throws {
        let anchor = capture.appending(path: "take1.anchor")
        chmod(anchor.path, 0o000)
        defer { chmod(anchor.path, 0o644) }
        let before = try package.xml()

        #expect(
            try await package.run("capture", "place", "PKG", "take1-1-1")
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: cannot read \(package.path)/Capture/take1.anchor: Permission denied.\n"))

        #expect(try package.xml() == before)
    }

    @Test(arguments: [["take1-1"], ["take0-1-1"], ["take1-1-1", "--at", "-1"]])
    func aBadSegmentNameOrStartExits64(arguments: [String]) async throws {
        let before = try package.xml()

        #expect(try await package.run(["capture", "place", "PKG"] + arguments).status == 64)

        #expect(try package.xml() == before)
    }

    // MARK: Criterion 20

    @Test func placeHasHelp() async throws {
        let help = try await dirigible("capture", "place", "--help")

        #expect(help.status == 0)
        #expect(
            help.stdout.contains("USAGE: dirigible capture place <package> <segment> [--track <track>] [--at <at>]"))
        #expect(help.stdout.contains("take anchor"))
    }

    /// Code gate 1 item 4: the disk refusal of a placement gives its own rule in bytes, not the
    /// 1 GB rule of a take start. No seam gives the binary a low disk, so the test reads the
    /// message of the error.
    @Test func aDiskRefusalGivesTheNeededAndFreeBytes() {
        let error = StudioError.placementSpace(needed: 1_073_813_824, free: 500_000)
        #expect(
            error.message(package: "Show.dirigible")
                == "the placement needs 1073813824 bytes free on the disk of Show.dirigible; 500000 bytes are free.")
    }
}
