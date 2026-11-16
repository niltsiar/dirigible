import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// `dirigible take map` (decision 0061, criteria C3 a and C6 of run 2026-10-22-take-sync).
struct TakeMapCommandTests {
    static let takeStart: UInt64 = 1_000_000_000_000

    /// A package with a pending take 1 that arms `t1` and `t2`, at playhead 0.
    static func pendingTake() throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.setRecording(
            Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: takeStart, armedTracks: ["t1", "t2"]))
        return try TemporaryPackage(session)
    }

    /// Writes a closed mono segment of take 1 with the real writer. Sample n is 2 x n / 2^23, a
    /// 24-bit value, so a sample of an export gives its file frame.
    static func rampSegment(_ package: TemporaryPackage, arm: Int, firstHost: UInt64, frames: Int) throws {
        let capture = package.url.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        let header = CaptureHeader(
            deviceUID: "usb-\(arm)", deviceName: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelCount: 1, latency: 0, firstSampleTime: 0, firstHostTimeNanos: firstHost)
        let writer = try SegmentWriter(
            folder: capture, name: SegmentName(take: 1, arm: arm, segment: 1), header: header)
        try writer.checkpoint(Checkpoint(fileFrame: 0, sampleTime: 0, hostTimeNanos: firstHost))
        let samples = (0..<frames).map { Float(2 * $0) / Float(1 << 23) }
        try samples.withUnsafeBufferPointer { try writer.write($0, frames: frames) }
        try writer.close()
    }

    /// The first sample of a 1-frame 24-bit export of `track` at timeline frame `frame`.
    static func exportedSample(_ package: TemporaryPackage, track: String, frame: Int) async throws -> Float {
        let wav = package.folder.appending(path: "\(track)-\(frame).wav")
        let result = try await package.run(
            "export", "PKG", "--out", wav.path, "--from", "\(frame)", "--to", "\(frame + 1)", "--track", track)
        try #require(result.status == 0, "export: \(result)")
        let file = try AVAudioFile(forReading: wav)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1))
        try file.read(into: buffer)
        return buffer.floatChannelData![0][0]
    }

    /// The places of each line of `take map`, by take frame: `nil` for `cut`.
    static func places(_ stdout: String) -> [Int: [(track: String, frame: Int)]?] {
        var found: [Int: [(track: String, frame: Int)]?] = [:]
        for line in stdout.split(separator: "\n") {
            let words = line.split(separator: " ")
            guard let frame = Int(words[0]) else { continue }
            found[frame] =
                words[1] == "cut"
                ? .some(nil)
                : words.dropFirst().map {
                    let parts = $0.split(separator: ":")
                    return (String(parts[0]), Int(parts[1]) ?? -1)
                }
        }
        return found
    }

    /// C3 (a): two capture files, the second 10 ms after the take start (take origin 480). After a
    /// ripple insert of 1 s at 0, a ripple delete of 2 s at 10 s, a ripple insert of 0.5 s at 20 s
    /// on t2 only, and a clip move, each mapped frame of a 1-frame export plays file frame t - origin.
    @Test func theMappedFrameHoldsTheTakeAudio() async throws {
        let package = try Self.pendingTake()
        try Self.rampSegment(package, arm: 1, firstHost: Self.takeStart, frames: 1_440_000)
        try Self.rampSegment(package, arm: 2, firstHost: Self.takeStart + 10_000_000, frames: 1_440_000)
        let finalize = try await package.run("take", "finalize", "PKG")
        try #require(finalize.status == 0, "take finalize: \(finalize)")
        let gains = try package.read().tracks.flatMap(\.clips).map(\.gain)
        try #require(gains == [.zero, .zero], "the take clips are not at 0 dB: \(gains)")
        for edit in [
            ["clip", "ripple-insert", "PKG", "--at", "0", "--length", "48000"],
            ["clip", "ripple-delete", "PKG", "--from", "480000", "--to", "576000"],
            ["clip", "ripple-insert", "PKG", "--at", "960000", "--length", "24000", "--track", "t2"],
        ] {
            let result = try await package.run(edit)
            try #require(result.status == 0, "\(edit): \(result)")
        }
        let last = try #require(package.read().track("t2")?.clips.last)
        let move = try await package.run(
            "clip", "move", "PKG", last.id.rawValue, "--track", "t2", "--start", "\(last.start.count + 48_000)")
        try #require(move.status == 0, "clip move: \(move)")

        let frames = [0, 24_000, 300_000, 431_999, 500_000, 528_000, 700_000, 1_100_000, 1_400_000]
        let result = try await package.run(["take", "map", "PKG"] + frames.map(String.init))
        #expect(result.status == 0 && result.stderr.isEmpty, "take map: \(result)")
        let mapped = Self.places(result.stdout)
        #expect(mapped.keys.sorted() == frames, "\(result.stdout)")
        // 432 000..<528 000 is the take time of the ripple delete on both tracks.
        #expect(mapped[500_000].map { $0 == nil } == true, "a deleted take frame is not cut: \(result.stdout)")
        // Take frame 0 is before the first frame of t2, whose origin is 480.
        #expect(mapped[0]??.map(\.track) == ["t1"], "\(result.stdout)")
        for frame in frames where ![0, 500_000].contains(frame) {
            #expect(mapped[frame]??.map(\.track).sorted() == ["t1", "t2"], "take frame \(frame): \(result.stdout)")
        }
        let origins = ["t1": 0, "t2": 480]
        for (frame, places) in mapped {
            for place in places ?? [] {
                let sample = try await Self.exportedSample(package, track: place.track, frame: place.frame)
                let expected = Float(2 * (frame - origins[place.track, default: 0])) / Float(1 << 23)
                #expect(abs(sample - expected) < 0.5 / Float(1 << 23), "take \(frame) at \(place): \(sample)")
            }
        }
    }

    /// Two takes with audio on `t1`, each placed by its anchor: take 1 at 0, and take 2, recorded
    /// at playhead 480 000, at 480 000.
    static func twoTakes() throws -> TemporaryPackage {
        try takes([(1, takeStart, 0), (2, takeStart + 60_000_000_000, 480_000)])
    }

    /// One 1 s clip on `t1` for each take of `starts`, at the playhead of its record start, with
    /// the anchor of each take from the real writer.
    static func takes(_ starts: [(take: Int, host: UInt64, playhead: Frames)]) throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        for (take, host, playhead) in starts {
            let id = "take\(take)-1-1"
            try session.addCapture(
                Capture(
                    id: CaptureID(id), deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: host, sampleTime: 0,
                    nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0, resampledFromRate: nil,
                    driftCorrected: true))
            try session.addFile(
                AudioFile(id: FileID(id), path: "\(id).wav", layout: .mono, length: 48_000, capture: CaptureID(id)))
            try session.place(
                Clip(id: ClipID(id), file: FileID(id), start: playhead, offset: 0, length: 48_000), on: "t1")
        }
        let package = try TemporaryPackage(session)
        try FileManager.default.createDirectory(
            at: package.url.appending(path: "Capture"), withIntermediateDirectories: true)
        for (take, host, playhead) in starts {
            try TakeAnchor.write(
                Recording(take: take, playheadFrame: playhead, takeStartHostTimeNanos: host, armedTracks: ["t1"]),
                in: package.url)
        }
        return package
    }

    @Test func twoTakesNeedTheTakeOption() async throws {
        let package = try Self.twoTakes()

        #expect(
            try await package.run("take", "map", "PKG", "100")
                == CLIResult(status: 64, stdout: "", stderr: "Error: Give --take: the session has takes 1, 2.\n"))
        #expect(try await package.run("take", "map", "PKG", "100", "--take", "1").stdout == "100 t1:100\n")
        #expect(
            try await package.run("take", "map", "PKG", "100", "48000", "--take", "2")
                == CLIResult(status: 0, stdout: "100 t1:480100\n48000 cut\n", stderr: ""))
        #expect(
            try await package.run("take", "map", "PKG", "--take", "2", "--json", "100")
                == CLIResult(
                    status: 0,
                    stdout: #"{"frames":[{"frame":100,"places":[{"frame":480100,"track":"t1"}]}],"take":2}"#
                        + "\n", stderr: ""))
        #expect(
            try await package.run("take", "map", "PKG", "100", "--take", "3")
                == CLIResult(
                    status: 1, stdout: "",
                    stderr: "Error: Take 3 has no audio with a take time. The session has takes 1, 2.\n"))
    }

    /// The inverse: the take frame of a timeline frame on each track, or none for a gap, another
    /// take, or a track with no clip there.
    @Test func theTimelineFlagGivesTheTakeFrame() async throws {
        let package = try Self.twoTakes()

        #expect(
            try await package.run("take", "map", "PKG", "--timeline", "--take", "2", "480100", "200000", "100")
                == CLIResult(status: 0, stdout: "480100 t1:100\n200000 none\n100 none\n", stderr: ""))
        #expect(
            try await package.run("take", "map", "PKG", "--timeline", "--take", "1", "--track", "t2", "100")
                == CLIResult(status: 0, stdout: "100 none\n", stderr: ""))
        #expect(
            try await package.run("take", "map", "PKG", "--timeline", "--take", "1", "--track", "t9", "100")
                == CLIResult(status: 1, stdout: "", stderr: "Error: no track \"t9\".\n"))
    }

    @Test func aSessionWithNoTakeAudioExitsOne() async throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        let package = try TemporaryPackage(session)

        #expect(
            try await package.run("take", "map", "PKG", "0")
                == CLIResult(status: 1, stdout: "", stderr: "Error: The session has no take audio with a take time.\n"))
    }

    @Test func aNegativeTimelineFrameExitsSixtyFour() async throws {
        let package = try Self.twoTakes()

        let result = try await package.run("take", "map", "PKG", "--take", "1", "--timeline", "-5")

        #expect(result.status == 64 && result.stdout.isEmpty, "\(result)")
        #expect(result.stderr.contains("Each frame must be 0 to 1099511627776."), "\(result.stderr)")
    }

    /// A capture file whose first frame is 10 ms before the take start has the origin -480. The
    /// finalize puts those frames into the clip offset; after a trim shows them, `--timeline` gives
    /// a take frame under 0, and that take frame maps back to the same place.
    @Test func aPrintedNegativeTakeFrameMapsBack() async throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRecording(
            Recording(take: 1, playheadFrame: 96_000, takeStartHostTimeNanos: Self.takeStart, armedTracks: ["t1"]))
        let package = try TemporaryPackage(session)
        try Self.rampSegment(package, arm: 1, firstHost: Self.takeStart - 10_000_000, frames: 48_000)
        let finalize = try await package.run("take", "finalize", "PKG")
        try #require(finalize.status == 0, "take finalize: \(finalize)")
        let trim = try await package.run("clip", "trim", "PKG", "take1-1-1", "--from", "95520", "--to", "143520")
        try #require(trim.status == 0, "clip trim: \(trim)")

        let timeline = try await package.run("take", "map", "PKG", "--timeline", "95520")
        let take = try await package.run("take", "map", "PKG", "-480")

        #expect(timeline == CLIResult(status: 0, stdout: "95520 t1:-480\n", stderr: ""))
        #expect(take == CLIResult(status: 0, stdout: "-480 t1:95520\n", stderr: ""))
    }

    /// C2: an anchor that does not read is not "no take audio": exit 2, as for a package that does
    /// not read, with the file and the errno.
    @Test func anAnchorReadFaultExitsTwo() async throws {
        let package = try Self.twoTakes()
        let anchor = package.url.appending(path: "Capture/take2.anchor")
        chmod(anchor.path, 0o000)
        defer { chmod(anchor.path, 0o644) }

        #expect(
            try await package.run("take", "map", "PKG", "--take", "2", "100")
                == CLIResult(
                    status: 2, stdout: "",
                    stderr:
                        "Error: Cannot read the take anchor file Capture/take2.anchor (errno 13), so the take time is "
                        + "not known.\n"))
    }

    /// The anchor fault of a pruned take 2 keeps only take 2 out: take 4 maps, and `info` shows
    /// the take 2 fault.
    @Test func anAnchorFaultBlocksOnlyItsTake() async throws {
        let package = try Self.takes([(4, Self.takeStart, 0)])
        try TakeAnchor.write(
            Recording(take: 2, playheadFrame: 0, takeStartHostTimeNanos: Self.takeStart, armedTracks: ["t1"]),
            in: package.url)
        let anchor = package.url.appending(path: "Capture/take2.anchor")
        chmod(anchor.path, 0o000)
        defer { chmod(anchor.path, 0o644) }

        let map = try await package.run("take", "map", "PKG", "--take", "4", "100")
        let info = try await package.run("info", "PKG")

        #expect(map == CLIResult(status: 0, stdout: "100 t1:100\n", stderr: ""))
        let lines = info.stdout.split(separator: "\n").filter { $0.hasPrefix("sync ") }
        #expect(
            info.status == 0
                && lines == [
                    "sync take 4 in sync, offset 0.000 s (0 frames)",
                    "sync anchor file unreadable: Capture/take2.anchor (errno 13)",
                ], "\(info)")
    }

    /// A `Capture/` that does not list stops the open: the item check of the open cannot see its
    /// entries.
    @Test func anUnreadableCaptureFolderStopsTheOpen() async throws {
        let package = try Self.twoTakes()
        let capture = package.url.appending(path: "Capture")
        chmod(capture.path, 0o000)
        defer { chmod(capture.path, 0o755) }

        #expect(
            try await package.run("take", "map", "PKG", "--take", "1", "100")
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: cannot read \(package.path)/Capture: Permission denied.\n"))
    }
}
