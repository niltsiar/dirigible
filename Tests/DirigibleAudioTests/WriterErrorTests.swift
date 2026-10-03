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
        try session.setRoute(Route.device(uid: "duo", channels: .mono(1)), track: "t1")
        try session.setRoute(Route.device(uid: "duo", channels: .mono(2)), track: "t2")
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
        if blocked {
            await until(limit: busy, "t1 has no write error") { studio.liveTracks["t1"]?.state == .writeFailed }
        }
        #expect(studio.liveTracks["t2"]?.state == .recording)
        input.play(run(&clock, 1.5, layout: [2]))
        await input.wait()
        await until(limit: busy, "t1 is not recording") { studio.liveTracks["t1"]?.state == .recording }
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

    /// A writer of arm 1 on channel 1 and arm 2 on channel 2 of `duo`, with the drain interval
    /// `drain`.
    func duoWriter(_ hal: TestHAL, drain: Duration) -> DeviceWriter {
        let url = folder.url
        let writer = DeviceWriter(
            device: duo, tracks: [(arm: 1, channels: .mono(1)), (arm: 2, channels: .mono(2))],
            files: TakeFiles(take: 1, folder: { url }), hal: hal.hal, report: log.closure, drainInterval: drain,
            silenceLimit: noWatchdog, firstRecordLimit: noWatchdog)
        writer.start()
        return writer
    }

    /// A directory at the sidecar path of arm 2 makes its first segment fail, and arm 2 reopens
    /// after 1 s of device frames. Before the reopen, arm 2 reports no written span but its peak,
    /// and arm 1 reports its span. After the reopen, arm 2 reports a span from the reopen.
    @Test func aFailedArmReportsNoWrittenSpan() async throws {
        try FileManager.default.createDirectory(
            at: folder.url.appending(path: "take1-2-1.sidecar"), withIntermediateDirectories: true)
        let hal = TestHAL([duo])
        let writer = duoWriter(hal, drain: .milliseconds(50))
        let input = SyntheticInput(hal, "duo")
        var clock = DeviceClock()

        input.play(run(&clock, 0.5, layout: [2]))
        await input.wait()
        // The failure is in an earlier drain than the reopen.
        await drained(hal, "duo")
        input.play(run(&clock, 1.5, layout: [2]))
        await input.wait()
        await writer.finish()

        let reports = log.all
        let reopen = try #require(reports.firstIndex { $0.state(arm: 2)?.0 == .recording }, "arm 2 did not reopen")
        let before = reports[..<reopen].compactMap(\.arms)
        let after = reports[reopen...].compactMap(\.arms)
        #expect(before.contains { $0[1]?.written != nil })
        #expect(
            before.allSatisfy { $0[2]?.written == nil },
            "arm 2 has a span of frames that it did not write (before the reopen)")
        #expect(before.allSatisfy { $0[1]?.written == nil || $0[2]?.peak == 0.25 }, "arm 2 has no peak")
        let reopened = after.compactMap { $0[2]?.written }
        let first = try #require(reopened.first, "arm 2 has no span after its reopen")
        #expect(
            abs(nanos(from: takeStart + 1_000_000_000, to: first.lowerBound)) <= 1000,
            "arm 2 has a span of frames that it did not write (at the reopen)")
        let arm1 = reports.compactMap { $0.arms?[1]?.written }
        #expect(abs(arm1.map { nanos(from: takeStart, to: $0.lowerBound) }.min() ?? .max) <= 1000)
        #expect(abs(arm1.map { nanos(from: takeStart + 2_000_000_000, to: $0.upperBound) }.max() ?? .max) <= 1000)
    }

    /// One drain: arm 2 writes 0.5 s, then a forward jump of 3 s starts a new segment whose open
    /// fails for arm 2, and arm 2 reopens 1 s of device frames later in the same drain. The span
    /// of arm 2 ends at its last written record, so it holds no gap. Arm 1 spans the whole drain.
    @Test func aWriteErrorEndsTheSpanInItsDrain() async throws {
        try FileManager.default.createDirectory(
            at: folder.url.appending(path: "take1-2-2.sidecar"), withIntermediateDirectories: true)
        let hal = TestHAL([duo])
        let writer = duoWriter(hal, drain: .seconds(60))
        let input = SyntheticInput(hal, "duo")
        var clock = DeviceClock()
        var records = run(&clock, 0.5, layout: [2])
        clock.sampleTime += 3 * 48_000
        records += run(&clock, 1.5, layout: [2])

        input.play(records)
        await input.wait()
        await writer.finish()

        #expect(log.states(arm: 2) == [.writeFailed, .recording])
        let levels = log.all.compactMap(\.arms)
        #expect(levels.count == 1)
        let arm1 = try #require(levels.first?[1]?.written, "arm 1 has no span")
        #expect(
            abs(nanos(from: takeStart, to: arm1.lowerBound)) <= 1000
                && abs(nanos(from: takeStart + 2_000_000_000, to: arm1.upperBound)) <= 1000,
            "the span of arm 1 is not the whole drain")
        let arm2 = try #require(levels.first?[2]?.written, "arm 2 has no span")
        #expect(
            abs(nanos(from: takeStart, to: arm2.lowerBound)) <= 1000
                && abs(nanos(from: takeStart + 500_000_000, to: arm2.upperBound)) <= 1000,
            "the span of arm 2 holds frames that it did not write")
    }

    /// One drain: 0.5 s, then a forward jump of 3 s in the sample time and the host time, then
    /// 0.5 s. The jump opens a new segment and no file holds the 3 s hole, so the span of each
    /// arm ends at its last record before the hole.
    @Test func aHostHoleEndsTheSpanInItsDrain() async throws {
        let hal = TestHAL([duo])
        let writer = duoWriter(hal, drain: .seconds(60))
        let input = SyntheticInput(hal, "duo")
        var clock = DeviceClock()
        var records = run(&clock, 0.5, layout: [2])
        clock.sampleTime += 3 * 48_000
        clock.hostNanos += 3e9
        records += run(&clock, 0.5, layout: [2])

        input.play(records)
        await input.wait()
        await writer.finish()

        let levels = log.all.compactMap(\.arms)
        #expect(levels.count == 1)
        for arm in [1, 2] {
            let span = try #require(levels.first?[arm]?.written, "arm \(arm) has no span")
            #expect(
                abs(nanos(from: takeStart, to: span.lowerBound)) <= 1000
                    && abs(nanos(from: takeStart + 500_000_000, to: span.upperBound)) <= 1000,
                "the span of arm \(arm) crosses the host hole")
        }
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
        try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
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
