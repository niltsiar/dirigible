import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The raw CAF removal of decision 0071 at a locked edit and in `take finalize` and `capture place`
/// (C11, C13). A locked edit removes only the CAF of a segment with a finalize record, and writes a
/// `-cli-` journal only at a fault.
extension TakeCommandTests {
    var capture: URL { package.url.appending(path: "Capture") }

    /// Finalizes take `take` with one 2.0 s segment on `t1` whose checkpoints pass the gate, and
    /// saves it with no sweep. With `record` false, the sidecar has no finalize record, as a take of
    /// a build before 0071. Take 1 is the pending take of `init`.
    func finalizedTake(_ take: Int, record: Bool) async throws {
        let start = Self.takeStart + UInt64(take - 1) * 10_000_000_000
        if take > 1 {
            try package.edit { session in
                try session.setRecording(
                    Recording(
                        take: take, playheadFrame: Frames((take - 1) * 192_000), takeStartHostTimeNanos: start,
                        armedTracks: ["t1"]))
            }
        }
        let name = SegmentName(take: take, arm: 1, segment: 1)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        let header = CaptureHeader(
            deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelCount: 1, latency: 0, firstSampleTime: 0, firstHostTimeNanos: start)
        let writer = try SegmentWriter(folder: capture, name: name, header: header)
        for frame in [0, 48_000, 95_999] {
            try writer.checkpoint(
                Checkpoint(
                    fileFrame: Int64(frame), sampleTime: Double(frame),
                    hostTimeNanos: start + UInt64(frame) * 62_500 / 3))
        }
        let samples = [Float](repeating: 0.25, count: 96_000)
        try samples.withUnsafeBufferPointer { try writer.write($0, frames: samples.count) }
        try writer.close()
        let outcome = await completeTake(of: try package.read(), lock: try PackageLock(package.url))
        try #require(outcome.error == nil, "finalize: \(String(describing: outcome.error))")
        let written = try #require(finalizeRecord(name), "the finalize writes a record")
        if !record {
            let sidecar = capture.appending(path: name.sidecarName)
            let size = try #require(try FileManager.default.attributesOfItem(atPath: sidecar.path)[.size] as? Int)
            try #require(truncate(sidecar.path, off_t(size - Sidecar.encode(written).count)) == 0)
            try #require(finalizeRecord(name) == nil)
        }
        try #require(rawCaptures(of: try package.read(), in: package.url)[name] == .removable)
    }

    func finalizeRecord(_ name: SegmentName) -> FinalizeRecord? {
        (try? Data(contentsOf: capture.appending(path: name.sidecarName))).flatMap { try? Sidecar.decode($0) }?
            .finalized
    }

    func hasCAF(_ stem: String) -> Bool {
        FileManager.default.fileExists(atPath: capture.appending(path: "\(stem).caf").path)
    }

    /// The lines of each `.tsv` journal in `logs`, by file name.
    static func journals(in logs: URL) throws -> [String: [Substring]] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []).filter {
            $0.hasSuffix(".tsv")
        }
        return try Dictionary(
            uniqueKeysWithValues: names.map { name in
                (
                    name,
                    String(decoding: try Data(contentsOf: logs.appending(path: name)), as: UTF8.self).split(
                        separator: "\n")
                )
            })
    }

    /// The one `-cli-` journal in `logs` has one `raw` line with errno 13 and ends with `app quit`.
    static func expectOneRawLine(in logs: URL) throws {
        let journals = try journals(in: logs)
        try #require(journals.count == 1 && journals.keys.first?.contains("-cli-") == true, "files: \(journals.keys)")
        let lines = try #require(journals.values.first)
        let raw = lines.filter { $0.contains("\traw\t") }
        #expect(raw.count == 1 && raw.first?.contains("errno=\(EACCES)") == true, "raw lines: \(raw)")
        #expect(lines.last?.split(separator: "\t").dropFirst(4).prefix(2) == ["app", "quit"], "lines: \(lines)")
    }

    /// C13: a locked edit removes the CAF of the take with a record, and keeps the CAF of the old take
    /// with no record, because it reads no audio. `take finalize` then removes that CAF.
    @Test func aMarkerSetRemovesOnlyTheCAFWithARecordAndFinalizeRemovesTheRest() async throws {
        try await finalizedTake(1, record: true)
        try await finalizedTake(2, record: false)
        let logs = package.folder.appending(path: "logs")

        let marker = try await dirigible(["marker", "set", package.path, "--name", "Note", "--at", "10"], logs: logs)

        #expect(marker.status == 0, "marker set: \(marker)")
        #expect(!hasCAF("take1-1-1"), "the locked edit removes the CAF of the take with a record")
        #expect(hasCAF("take2-1-1"), "the locked edit keeps the CAF of the old take with no record")
        #expect(try Self.journals(in: logs).isEmpty, "an edit with no fault writes no journal")

        #expect(try await package.run("take", "finalize", "PKG") == CLIResult(status: 0, stdout: "", stderr: ""))

        #expect(!hasCAF("take2-1-1"), "take finalize removes the CAF of the old take")
        #expect(finalizeRecord(SegmentName(take: 2, arm: 1, segment: 1)) != nil, "the sweep appends the record")
        for stem in ["take1-1-1", "take2-1-1"] {
            #expect(FileManager.default.fileExists(atPath: clips.appending(path: "\(stem).wav").path))
        }
    }

    /// C11: a locked edit that cannot unlink the CAF exits 0, keeps it, and writes one `raw` line.
    @Test func aMarkerSetThatCannotRemoveTheCAFWritesOneRawLine() async throws {
        try await finalizedTake(1, record: true)
        let logs = package.folder.appending(path: "logs")
        chmod(capture.path, 0o555)
        defer { chmod(capture.path, 0o755) }

        let marker = try await dirigible(["marker", "set", package.path, "--name", "Note", "--at", "10"], logs: logs)

        #expect(marker.status == 0, "marker set: \(marker)")
        #expect(hasCAF("take1-1-1"))
        try Self.expectOneRawLine(in: logs)
    }

    /// C11: `take finalize` that cannot unlink the CAF exits 0, keeps it, and writes one `raw` line.
    @Test func aTakeFinalizeThatCannotRemoveTheCAFWritesOneRawLine() async throws {
        try await finalizedTake(1, record: true)
        let logs = package.folder.appending(path: "logs")
        chmod(capture.path, 0o555)
        defer { chmod(capture.path, 0o755) }

        let result = try await dirigible(["take", "finalize", package.path], logs: logs)

        #expect(result == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(hasCAF("take1-1-1"))
        try Self.expectOneRawLine(in: logs)
    }

    /// C13: `capture place` removes the CAF of the segment that it places, after the sweep.
    @Test func aPlacementRemovesTheCAFOfItsSegment() async throws {
        try await finalizedTake(1, record: true)
        try package.edit { session in
            try session.removeClips(["take1-1-1"])
            try session.removeFile("take1-1-1")
        }
        #expect(hasCAF("take1-1-1"))

        let result = try await package.run("capture", "place", "PKG", "take1-1-1")

        #expect(result.status == 0 && result.stdout == "take1-1-1\n", "capture place: \(result)")
        #expect(!hasCAF("take1-1-1"), "the sweep after the placement removes the CAF")
    }

    /// Code gate item 8: before the unlink, the removal compares the finalize record with the CAF
    /// header frames and the rate choice. A record of other frames or of another source rate keeps
    /// the CAF at a locked edit and at `take finalize`. The record of the finalize removes it.
    @Test(arguments: ["none", "frames", "rate"]) func aRecordOfAnotherCAFKeepsTheCAF(fault: String) async throws {
        try await finalizedTake(1, record: true)
        let name = SegmentName(take: 1, arm: 1, segment: 1)
        var record = try #require(finalizeRecord(name))
        switch fault {
        case "frames": record.cafFrames -= 1
        case "rate": record.sourceRate = 44_100
        default: break
        }
        try #require(Sidecar.append(record, toSidecarAt: capture.appending(path: name.sidecarName)) == nil)
        try #require(finalizeRecord(name) == record, "the reader uses the last record")
        let logs = package.folder.appending(path: "logs")

        let marker = try await dirigible(["marker", "set", package.path, "--name", "Note", "--at", "10"], logs: logs)

        #expect(marker.status == 0, "marker set: \(marker)")
        #expect(hasCAF("take1-1-1") == (fault != "none"), "\(fault): the CAF stays only for a record of another CAF")
        guard fault != "none" else { return }
        let finalize = try await dirigible(["take", "finalize", package.path], logs: logs)
        #expect(finalize == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(hasCAF("take1-1-1"), "take finalize keeps the CAF too")
        #expect(FileManager.default.fileExists(atPath: clips.appending(path: "take1-1-1.wav").path))
    }
}
