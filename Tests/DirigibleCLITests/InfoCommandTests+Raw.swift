import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The `raw` lines of `info` and the `rawKept` entries of `info --json` and `session_info`
/// (decision 0071, C13): each CAF that a placed segment keeps, and why.
extension InfoCommandTests {
    static let rawTakeStart: UInt64 = 1_000_000_000_000

    /// A package with take 1 finalized and placed, with no sweep: one 2.0 s mono segment on track
    /// `t<arm>` for each bow, made with the real writer. A bow adds that many seconds to the host
    /// time of the middle checkpoint, so 1.07 ms keeps the CAF for its alignment and 0 passes the gate.
    /// With `finalized` false, take 1 stays the pending take.
    static func rawPackage(bows: [Double], finalized: Bool = true) async throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        let tracks = bows.indices.map { TrackID("t\($0 + 1)") }
        for track in tracks { try session.addTrack(track, name: track.rawValue, layout: .mono) }
        try session.setRecording(
            Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: rawTakeStart, armedTracks: tracks))
        let package = try TemporaryPackage(session)
        let capture = package.url.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        let header = CaptureHeader(
            deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelCount: 1, latency: 0, firstSampleTime: 0, firstHostTimeNanos: rawTakeStart)
        for (index, bow) in bows.enumerated() {
            let writer = try SegmentWriter(
                folder: capture, name: SegmentName(take: 1, arm: index + 1, segment: 1), header: header)
            for (frame, late) in [(0, 0.0), (48_000, bow), (95_999, 0.0)] {
                try writer.checkpoint(
                    Checkpoint(
                        fileFrame: Int64(frame), sampleTime: Double(frame),
                        hostTimeNanos: rawTakeStart + UInt64(frame) * 62_500 / 3 + UInt64((late * 1e9).rounded())))
            }
            let samples = [Float](repeating: 0.25, count: 96_000)
            try samples.withUnsafeBufferPointer { try writer.write($0, frames: samples.count) }
            try writer.close()
        }
        guard finalized else { return package }
        let outcome = await completeTake(of: try package.read(), lock: try PackageLock(package.url))
        try #require(outcome.error == nil, "finalize: \(String(describing: outcome.error))")
        return package
    }

    static func rawLines(_ text: String) -> [Substring] { text.split(separator: "\n").filter { $0.hasPrefix("raw ") } }

    /// The `rawKept` entries of a JSON view of the session, or nil when the key is left out.
    static func rawKept(_ json: String) throws -> [[String: String]]? {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], "\(json)")
        return root["rawKept"] as? [[String: String]]
    }

    /// C13: one `raw` line for each CAF that a placed segment keeps: the clause of the gate, or
    /// `not removed yet` for a segment that passes it. After the sweep of `take finalize`, the
    /// passing segment has no CAF and no line.
    @Test func aKeptCAFHasARawLine() async throws {
        let package = try await Self.rawPackage(bows: [1.07e-3, 0])

        let before = try await package.run("info", "PKG")

        #expect(before.status == 0, "\(before)")
        #expect(
            Self.rawLines(before.stdout) == [
                "raw take1-1-1 kept: alignment 1.07 ms", "raw take1-2-1 kept: not removed yet",
            ],
            "\(before.stdout)")
        #expect(try await package.run("take", "finalize", "PKG") == CLIResult(status: 0, stdout: "", stderr: ""))
        let after = try await package.run("info", "PKG")
        #expect(Self.rawLines(after.stdout) == ["raw take1-1-1 kept: alignment 1.07 ms"], "\(after.stdout)")
        #expect(!FileManager.default.fileExists(atPath: package.url.appending(path: "Capture/take1-2-1.caf").path))
    }

    /// C13 negative control: with no CAF of a placed segment, `info` has no `raw` line and the
    /// JSON has no `rawKept` key, and the clip of the segment stays.
    @Test func aPackageWithNoKeptCAFHasNoRawLine() async throws {
        let package = try await Self.rawPackage(bows: [0])
        #expect(try await package.run("take", "finalize", "PKG") == CLIResult(status: 0, stdout: "", stderr: ""))

        let text = try await package.run("info", "PKG")
        let json = try await package.run("info", "PKG", "--json")

        #expect(text.status == 0 && Self.rawLines(text.stdout).isEmpty, "\(text.stdout)")
        let placed = text.stdout.split(separator: "\n").contains {
            $0.hasPrefix("  clip ") && $0.contains(" file take1-1-1 ")
        }
        #expect(placed, "the segment stays placed: \(text.stdout)")
        #expect(try Self.rawKept(json.stdout) == nil, "\(json.stdout)")
    }

    /// Code gate item 4: each CAF in `Capture/` has one `raw` line and one `rawKept` entry, also a
    /// CAF that the gate does not read: `pending take` before the finalize, and `not placed` for a
    /// segment whose clip is gone. The placed segment beside it passes the gate.
    @Test(arguments: [false, true]) func eachCAFInCaptureHasARawLine(finalized: Bool) async throws {
        let package = try await Self.rawPackage(bows: [0, 0], finalized: finalized)
        if finalized {
            var session = try package.read()
            try session.removeClips(["take1-1-1"])
            try session.write(to: package.url)
        }
        let kept =
            finalized
            ? [("take1-1-1", "not placed"), ("take1-2-1", "not removed yet")]
            : [("take1-1-1", "pending take"), ("take1-2-1", "pending take")]

        let text = try await package.run("info", "PKG")
        let json = try await package.run("info", "PKG", "--json")

        #expect(Self.rawLines(text.stdout) == kept.map { "raw \($0.0) kept: \($0.1)" }, "\(text.stdout)")
        #expect(try Self.rawKept(json.stdout) == kept.map { ["segment": $0.0, "reason": $0.1] }, "\(json.stdout)")
    }

    /// Code gate item 2: a segment with no finalize record and a saturated record of its CAF
    /// frames keeps its CAF with the reason `saturated WAV`, also after `take finalize`. A
    /// saturated record of other frames names another CAF, so the segment is not removed yet.
    @Test(arguments: [Int64(96_000), 95_999]) func aSaturatedRecordGivesItsRawLine(frames: Int64) async throws {
        let package = try await Self.rawPackage(bows: [0])
        let sidecar = package.url.appending(path: "Capture/take1-1-1.sidecar")
        let record = try #require(try Sidecar.decode(Data(contentsOf: sidecar))?.finalized)
        let size = try Data(contentsOf: sidecar).count
        try #require(truncate(sidecar.path, off_t(size - Sidecar.encode(record).count)) == 0)
        try #require(Sidecar.append(Sidecar.encode(saturated: frames), toSidecarAt: sidecar) == nil)
        let reason = frames == 96_000 ? "saturated WAV" : "not removed yet"

        let before = try await package.run("info", "PKG")

        #expect(Self.rawLines(before.stdout) == ["raw take1-1-1 kept: \(reason)"], "\(before.stdout)")
        guard frames == 96_000 else { return }
        #expect(try await package.run("take", "finalize", "PKG") == CLIResult(status: 0, stdout: "", stderr: ""))
        let after = try await package.run("info", "PKG")
        #expect(Self.rawLines(after.stdout) == ["raw take1-1-1 kept: saturated WAV"], "\(after.stdout)")
    }

    /// C13: `info --json` and `session_info` have `rawKept` with the entries of the `raw` lines,
    /// in segment order. A `session_info` of one track keeps only the entry of its file.
    @Test func rawKeptHasTheEntriesOfTheRawLines() async throws {
        let package = try await Self.rawPackage(bows: [1.07e-3, 0])

        let json = try await package.run("info", "PKG", "--json")
        let answers = try await mcp([
            toolCall(1, "session_info", ["package": package.path]),
            toolCall(2, "session_info", ["package": package.path, "tracks": ["t2"]]),
        ])
        let (text, isError) = toolResult(answer(answers, id: 1))

        let expected = [
            ["segment": "take1-1-1", "reason": "alignment 1.07 ms"],
            ["segment": "take1-2-1", "reason": "not removed yet"],
        ]
        #expect(json.status == 0 && !isError, "\(json) \(text)")
        #expect(try Self.rawKept(json.stdout) == expected, "\(json.stdout)")
        #expect(try Self.rawKept(text) == expected, "\(text)")
        let track = toolResult(answer(answers, id: 2)).text
        #expect(try Self.rawKept(track) == [expected[1]], "\(track)")
    }
}
