import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// `Studio.record(armed:playhead:for:)`, the call of `dirigible record` (criteria 16 and 23).
@MainActor
struct RecordTests {
    let folder: TemporaryFolder
    let url: URL
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!
    let box = InputDevice(
        uid: "box", name: "Box", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    /// Track `t1` on `mic` and track `t2` on `box`, both mono.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.setRoute(Route(deviceUID: "mic", channels: .mono(1)), track: "t1")
        try session.setRoute(Route(deviceUID: "box", channels: .mono(1)), track: "t2")
        try session.write(to: url)
    }

    func studio(_ hal: TestHAL, silenceLimit: Duration = .seconds(60)) async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(hal, silenceLimit: silenceLimit)
        return studio
    }

    /// A clock whose records come 0.1 s after now, so they are after the take start that the
    /// live start saves.
    func clock() -> DeviceClock {
        DeviceClock(hostNanos: Double(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())) + 100_000_000)
    }

    func clipIDs(_ studio: Studio, _ track: TrackID) -> [ClipID] {
        studio.session.track(track).map { $0.clips.map(\.id) } ?? []
    }

    // MARK: Criterion 16

    /// 3 s of records from before the take start: the finalize cuts the frames before the take
    /// start, and the writer the frames after its end, so the stop time does not matter.
    /// Control: 0.5 s.
    @Test(arguments: [1.0, 0.5])
    func aTimedRecordStopsAfterItsDuration(seconds: Double) async throws {
        let hal = TestHAL([mic])
        let studio = try await studio(hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock(hostNanos: Double(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())))
        input.play(clock.run(seconds: 3))

        let result = try await studio.record(armed: ["t1"], playhead: 0, for: .seconds(seconds))
        await input.wait()

        #expect(result == TakeResult(take: 1, end: .requested, gaps: [:]))
        #expect(studio.lastTake == result)
        #expect(studio.transport == .idle)
        #expect(clipIDs(studio, "t1") == ["take1-1-1"])
        let length = try #require(studio.session.track("t1")?.clips.first?.length.count)
        #expect(abs(length - Int(seconds * 48_000)) <= 480, "length \(length)")
        #expect(studio.session.track("t1")?.clips.first?.start == 0)
    }

    /// A take that ends early returns soon after its end, not after the full duration: a disk
    /// low stop, and a stop from another caller. The limit is 10 s less than the duration,
    /// because a full suite can hold the main actor for 30 s.
    @Test(arguments: [TakeEnd.diskLow, .requested])
    func aTimedTakeThatEndsEarlyReturnsSoon(end: TakeEnd) async throws {
        let free = FreeBytes()
        let hal = TestHAL([mic])
        let studio = try await Studio.open(url)
        studio.environment = .test(hal, free: free)
        let stopper = Task { @MainActor in
            await until(limit: .seconds(10), "the take did not start") { studio.transport == .recording(take: 1) }
            if end == .diskLow { free.value = 0 } else { try? await studio.stopRecording() }
        }
        let start = ContinuousClock.now

        let result = try await studio.record(armed: ["t1"], playhead: 0, for: .seconds(60))
        await stopper.value

        #expect(ContinuousClock.now - start < .seconds(50), "returned after \(ContinuousClock.now - start)")
        #expect(result.end == end)
        #expect(studio.transport == .idle)
    }

    /// A cancelled call stops its take at once, as an early end, and returns its result. Before
    /// the fix, the wait spun on the main actor until the deadline. The limit is 10 s less than
    /// the duration, because a full suite can hold the main actor for 30 s.
    @Test func aCancelledRecordStopsItsTake() async throws {
        let hal = TestHAL([mic])
        let studio = try await studio(hal)
        let recorder = Task { @MainActor in try await studio.record(armed: ["t1"], playhead: 0, for: .seconds(60)) }
        await until(limit: .seconds(10), "the take did not start") { studio.transport == .recording(take: 1) }
        let start = ContinuousClock.now

        recorder.cancel()
        let result = try await recorder.value

        #expect(ContinuousClock.now - start < .seconds(50), "returned after \(ContinuousClock.now - start)")
        #expect(result == TakeResult(take: 1, end: .requested, gaps: [:]))
        #expect(studio.transport == .idle)
        #expect(studio.pendingTake == nil)
    }

    // MARK: Criterion 23: the take result

    /// The attach of each device in `failing` always throws. Control: none fails, no gap.
    @Test(arguments: [[], ["box"], ["mic", "box"]] as [Set<String>])
    func aDeviceThatDoesNotAttachIsAGap(failing: Set<String>) async throws {
        let hal = TestHAL([mic, box])
        hal.failAttach { uid, _ in failing.contains(uid) ? .status(kAudioHardwareBadDeviceError) : nil }
        let studio = try await studio(hal)
        let micInput = SyntheticInput(hal, "mic")
        let boxInput = SyntheticInput(hal, "box")
        var micClock = clock()
        var boxClock = clock()
        if !failing.contains("mic") { micInput.play(micClock.run(seconds: 0.5)) }
        if !failing.contains("box") { boxInput.play(boxClock.run(seconds: 0.5)) }

        let result = try await studio.record(armed: ["t1", "t2"], playhead: 0, for: .seconds(1))
        await micInput.wait()
        await boxInput.wait()

        let gaps = Dictionary(
            uniqueKeysWithValues: failing.map { (TrackID($0 == "mic" ? "t1" : "t2"), TakeResult.Gap.deviceLost) })
        #expect(result == TakeResult(take: 1, end: .requested, gaps: gaps))
        #expect(clipIDs(studio, "t1") == (failing.contains("mic") ? [] : ["take1-1-1"]))
        #expect(clipIDs(studio, "t2") == (failing.contains("box") ? [] : ["take1-2-1"]))
    }

    /// Records without valid times never restart the watchdog, so the device is lost and the
    /// track has no clip: exit 5 in the CLI. Control: valid times give no gap.
    @Test(arguments: [false, true])
    func recordsWithoutValidTimesAreAGapWithNoClip(invalid: Bool) async throws {
        let hal = TestHAL([mic])
        let studio = try await studio(hal, silenceLimit: .milliseconds(300))
        let input = SyntheticInput(hal, "mic")
        var clock = clock()
        input.play(clock.run(seconds: 10), pace: .realTime, flags: invalid ? [] : validTimes)

        let result = try await studio.record(armed: ["t1"], playhead: 0, for: .seconds(1))
        await input.wait()

        #expect(result.gaps == (invalid ? ["t1": .deviceLost] : [:]))
        #expect(clipIDs(studio, "t1") == (invalid ? [] : ["take1-1-1"]))
        #expect(studio.clipIDs(ofTake: 1) == (invalid ? [] : ["take1-1-1"]))
    }
}
