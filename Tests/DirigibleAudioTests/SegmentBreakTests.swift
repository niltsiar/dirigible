import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A synthetic device clock. Each record holds 10 ms of frames at the real rate, all 0.25, and
/// carries the header rate as its nominal rate.
struct DeviceClock {
    var sampleTime: Double = 0
    var hostNanos: Double = Double(takeStart)
    var headerRate: Double = 48_000
    var realRate: Double = 48_000

    /// The records of `seconds`. `jitter` moves the host time of each record by up to that many
    /// nanoseconds either way, and does not add up.
    mutating func run(seconds: Double, jitter: Double = 0, using generator: inout SeededGenerator) -> [InputRecord] {
        let frames = Int((realRate / 100).rounded())
        return (0..<Int((seconds * 100).rounded())).map { _ in
            let noise = jitter == 0 ? 0 : Double.random(in: -jitter...jitter, using: &generator)
            let record = InputRecord(
                sampleTime: sampleTime, hostTimeNanos: UInt64(hostNanos + noise), frameCount: frames,
                nominalRate: headerRate, buffers: [[Float](repeating: 0.25, count: frames)])!
            sampleTime += Double(frames)
            hostNanos += Double(frames) / realRate * 1e9
            return record
        }
    }

    mutating func run(seconds: Double) -> [InputRecord] {
        var generator = SeededGenerator(seed: 1)
        return run(seconds: seconds, using: &generator)
    }
}

/// The clock events that start a new segment of a take (criterion 15, decision 0004).
@MainActor
struct SegmentBreakTests {
    let folder: TemporaryFolder
    let url: URL
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [44_100...44_100, 48_000...48_000],
        channelsPerBuffer: [1], latency: 0)!

    /// Track `t1` on channel 1 of `mic`.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRoute(Route(deviceUID: "mic", channels: .mono(1)), track: "t1")
        try session.write(to: url)
    }

    /// Records take 1 from `records` and stops it. Returns the studio after the stop.
    func take(_ records: [InputRecord]) async throws -> Studio {
        let studio = try await Studio.open(url)
        let hal = TestHAL([mic])
        studio.environment = .test(hal)
        _ = try await studio.startTake(armed: ["t1"], devices: [mic], playhead: 0, hostTimeNanos: takeStart)
        let input = SyntheticInput(hal, "mic")
        input.play(records)
        // The slow suite writes 1.4 GB at the same time, so the 24 flushes of a 120 s take can
        // take more than the default limit.
        await input.wait(limit: .seconds(60))
        try await studio.stopRecording()
        #expect(studio.takeError == nil)
        return studio
    }

    func clips(_ studio: Studio) -> [Clip] {
        studio.session.track("t1").map { Array($0.clips) } ?? []
    }

    /// The clip of segment `stem` with no offset.
    func clip(_ stem: String, start: Int, length: Int) -> Clip {
        Clip(
            id: ClipID(stem), file: FileID(stem), start: Frames(start), offset: 0, length: Frames(length))
    }

    @Test func aTakeWithNoEventIsOneSegment() async throws {
        var clock = DeviceClock()

        let studio = try await take(clock.run(seconds: 2))

        #expect(clips(studio) == [clip("take1-1-1", start: 0, length: 96_000)])
    }

    enum Event: String, CaseIterable, Sendable {
        case headerRate, byteSize, backwardJump, forwardJump
    }

    @Test(arguments: Event.allCases)
    func anEventStartsSegmentTwo(event: Event) async throws {
        var clock = DeviceClock()
        var records = clock.run(seconds: 1)
        // (start, length) of the second clip.
        let expected: (Int, Int)
        switch event {
        case .headerRate:
            clock.headerRate = 44_100
            clock.realRate = 44_100
            expected = (48_000, 48_000)
        case .byteSize:
            // A second buffer whose size is not a whole number of frames. The record is dropped;
            // its time passes. (A record of another layout re-routes: DeviceEventTests.)
            var bad = clock.run(seconds: 0.01)[0]
            bad.buffers = [[Float](repeating: 0.25, count: 480), [Float](repeating: 0.25, count: 481)]
            records.append(bad)
            expected = (48_480, 48_000)
        case .backwardJump:
            clock.sampleTime -= 48_000
            expected = (48_000, 48_000)
        case .forwardJump:
            clock.sampleTime += 3 * 48_000
            clock.hostNanos += 3e9
            expected = (192_000, 48_000)
        }
        records += clock.run(seconds: 1)

        let studio = try await take(records)

        let placed = clips(studio)
        #expect(placed.map(\.id) == ["take1-1-1", "take1-1-2"])
        #expect(placed.first == clip("take1-1-1", start: 0, length: 48_000))
        let second = try #require(placed.last)
        #expect(second.start.count == expected.0)
        #expect(abs(second.length.count - expected.1) <= 1)
    }

    @Test func aLaterSegmentWinsAnOverlap() async throws {
        var clock = DeviceClock()
        var records = clock.run(seconds: 1)
        // The clock starts again, and its host time is 0.5 s back.
        clock.sampleTime = 0
        clock.hostNanos -= 0.5e9
        records += clock.run(seconds: 1)

        let studio = try await take(records)

        #expect(
            clips(studio) == [
                clip("take1-1-1", start: 0, length: 24_000), clip("take1-1-2", start: 24_000, length: 48_000),
            ])
    }

    @Test func aForwardJumpOf1SecondIsFilledWithSilence() async throws {
        var clock = DeviceClock()
        var records = clock.run(seconds: 1)
        clock.sampleTime += 48_000
        clock.hostNanos += 1e9
        records += clock.run(seconds: 1)

        let studio = try await take(records)

        #expect(clips(studio) == [clip("take1-1-1", start: 0, length: 144_000)])
        let samples = try readAudio(url.appending(path: "Capture/take1-1-1.caf")).samples
        #expect(samples.count == 144_000)
        #expect(Set(samples[..<48_000]) == [0.25])
        #expect(Set(samples[48_000..<96_000]) == [0])
        #expect(Set(samples[96_000...]) == [0.25])
    }

    @Test func hostJitterOf200MicrosecondsStaysOneSegment() async throws {
        var clock = DeviceClock()
        var generator = SeededGenerator(seed: 15)

        let studio = try await take(clock.run(seconds: 120, jitter: 200_000, using: &generator))

        #expect(clips(studio).map(\.id) == ["take1-1-1"])
    }

    /// The real rate changes 1 s before the header rate shows it (decision 0004).
    @Test func aRateChangeBeforeTheHeaderRateIsSnappedByRuleTwo() async throws {
        var clock = DeviceClock()
        var records = clock.run(seconds: 10)
        clock.realRate = 44_100
        records += clock.run(seconds: 1)
        clock.headerRate = 44_100
        records += clock.run(seconds: 1)

        let studio = try await take(records)

        let placed = clips(studio)
        #expect(placed.map(\.id) == ["take1-1-1", "take1-1-2", "take1-1-3"])
        #expect(placed.map(\.start) == placed.map(\.start).sorted())
        let lagged = try #require(studio.session.captures["take1-1-2"])
        #expect(lagged.nominalSampleRate == 44_100)
        #expect(lagged.resampledFromRate == 44_100)
        #expect(lagged.driftCorrected)
        // The window of 0.5 s stays in segment 1, so segment 2 starts in the first 0.5 s.
        #expect((480_000...504_000).contains(placed[1].start.count))
        #expect(studio.session.captures["take1-1-3"]?.nominalSampleRate == 44_100)
        #expect(placed[2].start == 528_000)
    }
}
