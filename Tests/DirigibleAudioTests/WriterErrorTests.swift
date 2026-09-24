import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A write error on one track (criterion 10): the track reopens after 1 s of device frames, and
/// the other track of the device records on. The fixture is in `DeviceEventTests`.
extension DeviceEventTests {
    /// A directory at the sidecar path of `t1` makes its first segment fail to open. Control:
    /// without it, `t1` has one clip from the take start.
    @Test(arguments: [false, true])
    func aTrackWithAWriteErrorReopensAfterOneSecond(blocked: Bool) async throws {
        let url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.setRoute(Route(deviceUID: "duo", channels: .mono(1)), track: "t1")
        try session.setRoute(Route(deviceUID: "duo", channels: .mono(2)), track: "t2")
        try session.write(to: url)
        let studio = try await Studio.open(url)
        let hal = TestHAL([duo])
        studio.environment = .test(hal)
        let writers = try await studio.startTake(
            armed: ["t1", "t2"], devices: [duo], playhead: 0, hostTimeNanos: takeStart)
        // After the start, so the take number stays 1; before the first record, so the open fails.
        if blocked {
            try FileManager.default.createDirectory(
                at: url.appending(path: "Capture/take1-1-1.sidecar"), withIntermediateDirectories: true)
        }
        let input = SyntheticInput(hal, "duo")
        var clock = DeviceClock()

        input.play(run(&clock, 0.5, layout: [2]))
        await input.wait()
        if blocked { await until("t1 has no write error") { studio.liveTracks["t1"]?.state == .writeFailed } }
        #expect(studio.liveTracks["t2"]?.state == .recording)
        input.play(run(&clock, 1.5, layout: [2]))
        await input.wait()
        await until("t1 is not recording") { studio.liveTracks["t1"]?.state == .recording }
        let gaps = await writers["duo"]?.finish()
        try await studio.stopRecording()

        #expect(gaps == (blocked ? [1: .writeFailed] : [:]))
        let t1 = try #require(clips(studio, "t1").first)
        #expect(clips(studio, "t1").count == 1)
        #expect(t1.id == (blocked ? "take1-1-2" : "take1-1-1"))
        #expect(abs(t1.start.count - (blocked ? 48_000 : 0)) <= 480)
        #expect(t1.length == (blocked ? 48_000 : 96_000))
        #expect(clips(studio, "t2").map(\.id) == ["take1-2-1"])
        #expect(clips(studio, "t2").first?.start == 0)
        #expect(clips(studio, "t2").first?.length == 96_000)
    }

    /// The report of a write error carries the raw status (EISDIR for the open of a directory).
    @Test func aWriteErrorReportsItsStatusAndAGap() async throws {
        try FileManager.default.createDirectory(
            at: folder.url.appending(path: "take1-1-1.sidecar"), withIntermediateDirectories: true)
        let hal = TestHAL([mic])
        let writer = writer(mic, hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()

        input.play(run(&clock, 1.5))
        await input.wait()
        let gaps = await writer.finish()

        #expect(gaps == [1: .writeFailed])
        #expect(log.states(arm: 1) == [.writeFailed, .recording])
        #expect(log.statuses(arm: 1) == [EISDIR, nil])
        #expect(try stems() == ["take1-1-2"])
        #expect(try samples("take1-1-2").count == 24_000)
    }

    /// Slow: on a disk image, a full disk fails a write of `t1`; after the filler goes, the next
    /// segment opens, so the track has a clip before and after the error.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aTrackReopensAfterAFullDiskHasRoomAgain() async throws {
        let image = folder.url.appending(path: "full.dmg")
        let volume = folder.url.appending(path: "volume")
        try await offMainActor {
            try FullDiskTests.hdiutil(
                "create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigibleReopen", image.path)
            try FullDiskTests.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        }
        defer { FullDiskTests.run(["detach", volume.path, "-force"]) }
        let url = volume.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRoute(Route(deviceUID: "mic", channels: .mono(1)), track: "t1")
        try session.write(to: url)
        let studio = try await Studio.open(url)
        let hal = TestHAL([mic])
        studio.environment = .test(hal)
        _ = try await studio.startTake(armed: ["t1"], devices: [mic], playhead: 0, hostTimeNanos: takeStart)
        let filler = volume.appending(path: "filler")
        // 3 s of mono is 576,000 bytes of CAF.
        try await offMainActor { try FullDiskTests.fill(volume, leaving: 300_000, with: filler) }
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()

        input.play(run(&clock, 3))
        await input.wait()
        await until(limit: .seconds(5), "t1 has no write error") { studio.liveTracks["t1"]?.state == .writeFailed }
        try FileManager.default.removeItem(at: filler)
        input.play(run(&clock, 2))
        await input.wait()
        await until(limit: .seconds(5), "t1 is not recording") { studio.liveTracks["t1"]?.state == .recording }
        try await studio.stopRecording()

        #expect(studio.takeError == nil)
        let clips = clips(studio, "t1")
        #expect(clips.count == 2, "\(clips.map(\.id))")
        #expect(clips.first?.id == "take1-1-1")
    }
}
