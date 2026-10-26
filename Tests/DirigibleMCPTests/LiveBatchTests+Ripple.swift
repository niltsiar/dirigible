import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The ripple rule of each step of a live batch (decisions 0037 and 0046).
@MainActor
extension LiveBatchTests {
    /// Take 1 with a 1 s segment on `t1` and on `t2`, finalized, so both are placed. The clip of
    /// `take1-2-1` is removed, so a `file_remove` of its file splits the take. Gives the file ID.
    static func takePackage() throws -> (LivePackage, file: String) {
        let package = try LivePackage()
        var session = try Session(contentsOf: package.url)
        let recording = Recording(
            take: 1, playheadFrame: 0, takeStartHostTimeNanos: takeStart, armedTracks: ["t1", "t2"])
        try session.setRecording(recording)
        try session.write(to: package.url)
        let capture = package.url.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        for arm in [1, 2] {
            let header = CaptureHeader(
                deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
                channelCount: 1, latency: 48, firstSampleTime: 512, firstHostTimeNanos: takeStart + 10_000_000)
            let writer = try SegmentWriter(
                folder: capture, name: SegmentName(take: 1, arm: arm, segment: 1), header: header)
            let checkpoint = Checkpoint(fileFrame: 0, sampleTime: 512, hostTimeNanos: takeStart + 10_000_000)
            try writer.checkpoint(checkpoint)
            try [Float](repeating: 0.25, count: 48_000).withUnsafeBufferPointer { try writer.write($0, frames: 48_000) }
            try writer.close()
        }
        var finalized = try finalizeTake(of: Session(contentsOf: package.url), in: package.url)
        let second = try #require(finalized.files.first { $0.value.capture == CaptureID("take1-2-1") }?.key)
        try finalized.removeClips(finalized.tracks.flatMap(\.clips).filter { $0.file == second }.map(\.id))
        try finalized.write(to: package.url)
        return (package, second.rawValue)
    }

    static func ripple(_ to: Int = 4_800) -> Call { call("clip_ripple_delete", ["from": [0], "to": [to]]) }

    /// C8: a step that splits a take blocks a later ripple step, as the same calls one by one.
    @Test func aStepThatSplitsATakeBlocksALaterRipple() async throws {
        let (package, file) = try Self.takePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let before = studio.session
        let split = StudioError.rippleBlocked.message(package: package.path)

        let outcome = await batch(
            [Self.call("file_remove", ["file": file]), Self.ripple()], to: folder.socket, package: package)
        #expect(outcome == Self.refused(1, "clip_ripple_delete", split), "BATCH-S3-8 \(outcome)")
        #expect(studio.session == before && !studio.canUndo)

        let removed = await send(folder.socket, "file_remove", ["package": package.path, "file": file])
        let alone = await send(
            folder.socket, "clip_ripple_delete", ["package": package.path, "from": [0], "to": [4_800]])
        #expect(removed == Self.reply("OK") && alone == Self.reply(split, isError: true), "\(removed) \(alone)")
        await studio.settle()
    }

    /// C9: under a pending take, a batch of steps with no ripple runs, as one call does. A ripple
    /// step is refused at its index, and the steps before it change nothing.
    @Test func aPendingTakeRefusesOnlyARippleStep() async throws {
        let package = try LivePackage()
        try package.addPendingTake()
        let studio = try await package.open(pending: 1)
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let rename = Self.call("track_rename", ["track": "t2", "name": "Jingle"])

        let plain = await batch(
            [rename, Self.call("track_gain", ["track": "t1", "db": -3])], to: folder.socket, package: package)
        #expect(plain == Self.reply("calls[0] track_rename: OK\ncalls[1] track_gain: OK"), "\(plain)")
        let before = studio.session

        let outcome = await batch(
            [Self.call("track_rename", ["track": "t2", "name": "Other"]), Self.ripple()], to: folder.socket,
            package: package)

        let split = StudioError.rippleBlocked.message(package: package.path)
        #expect(outcome == Self.refused(1, "clip_ripple_delete", split), "\(outcome)")
        #expect(studio.session == before)
        await studio.settle()
    }
}
