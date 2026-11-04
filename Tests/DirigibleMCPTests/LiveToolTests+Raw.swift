import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio
@testable import DirigibleMCP

extension LiveToolTests {
    /// C13 of decision 0071 and decision 0046: a live `session_info` has the `rawKept` entries that
    /// the files give. Take 1 on `t1` has a 1.07 ms bow at its middle checkpoint, so the
    /// finalize at the open keeps its CAF for the alignment clause.
    @Test func liveInfoHasTheRawKeptEntries() async throws {
        let package = try LivePackage()
        var session = try Session(contentsOf: package.url)
        try session.setRecording(
            Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: takeStart, armedTracks: ["t1"]))
        try session.write(to: package.url)
        let capture = package.url.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        let header = CaptureHeader(
            deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelCount: 1, latency: 0, firstSampleTime: 0, firstHostTimeNanos: takeStart)
        let writer = try SegmentWriter(folder: capture, name: SegmentName(take: 1, arm: 1, segment: 1), header: header)
        for (frame, late) in [(0, UInt64(0)), (48_000, 1_070_000), (95_999, 0)] {
            try writer.checkpoint(
                Checkpoint(
                    fileFrame: Int64(frame), sampleTime: Double(frame),
                    hostTimeNanos: takeStart + UInt64(frame) * 62_500 / 3 + late))
        }
        let samples = [Float](repeating: 0.25, count: 96_000)
        try samples.withUnsafeBufferPointer { try writer.write($0, frames: samples.count) }
        try writer.close()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let info = replyText(await send(folder.socket, "session_info", ["package": package.path]))

        let root = try JSONSerialization.jsonObject(with: Data(info.utf8)) as? [String: Any]
        #expect(
            root?["rawKept"] as? [[String: String]] == [["segment": "take1-1-1", "reason": "alignment 1.07 ms"]],
            "session_info: \(info)")
        let settled = OSAllocatedUnfairLock(initialState: false)
        Task {
            await studio.settle()
            settled.withLock { $0 = true }
        }
        await until("the settle of the studio ends") { settled.withLock { $0 } }
    }
}
