import CoreAudio
import DirigibleCore
import Foundation
import Observation
import Testing

@testable import DirigibleAudio

/// The meter feed of decision 0014 (record-ui criteria 4, 5, and 6): the drain sends the peak of
/// each track and the dropped frames, and `Studio` is observable.
@MainActor
struct LevelTests {
    let folder: TemporaryFolder
    let url: URL
    let duo = InputDevice(
        uid: "duo", name: "Duo", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [2],
        latency: 0)!

    /// Track `t1` on channel 1 and track `t2` on channel 2 of `duo`.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.setRoute(Route(deviceUID: "duo", channels: .mono(1)), track: "t1")
        try session.setRoute(Route(deviceUID: "duo", channels: .mono(2)), track: "t2")
        try session.write(to: url)
    }

    func studio(_ hal: TestHAL, ringSeconds: Double = 10) async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(hal)
        studio.environment.ringSeconds = ringSeconds
        return studio
    }

    /// `seconds` of 10 ms records after now: a sine with amplitude 0.5 on channel 1 and silence on
    /// channel 2.
    func toneOnChannelOne(seconds: Double) -> [InputRecord] {
        let tone = sine(seconds: seconds, rate: 48_000)
        let interleaved = tone.flatMap { sample -> [Float] in [sample, 0] }
        let now = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) + 100_000_000
        return records([interleaved], layout: [2], rate: 48_000, frames: 480, hostStart: now)
    }

    // MARK: Criterion 4

    /// Control in the same poll: the silent channel reads 0.
    @Test func eachTrackGetsThePeakOfItsOwnChannel() async throws {
        let hal = TestHAL([duo])
        let studio = try await studio(hal)
        try await studio.startRecording(armed: ["t1", "t2"], playhead: 0)
        let input = SyntheticInput(hal, "duo")
        input.play(toneOnChannelOne(seconds: 3), pace: .realTime)

        await until(limit: .seconds(5), "t1 has no peak of 0.5") {
            abs((studio.liveTracks["t1"]?.peak ?? 0) - 0.5) <= 0.01
        }
        let silent = try #require(studio.liveTracks["t2"]?.peak)
        #expect(abs(silent) <= 1e-6)
        try await studio.stopRecording()
        await input.wait()
    }

    // MARK: Criterion 5

    /// A ring of 0.1 s gets 3 s of records at once, so it drops. Control: a ring of 10 s drops
    /// nothing.
    @Test(arguments: [0.1, 10])
    func droppedFramesReachTheStoredState(ringSeconds: Double) async throws {
        let hal = TestHAL([duo])
        let studio = try await studio(hal, ringSeconds: ringSeconds)
        try await studio.startRecording(armed: ["t1", "t2"], playhead: 0)
        let input = SyntheticInput(hal, "duo")
        input.play(toneOnChannelOne(seconds: 3), pace: .ignoreRoom)
        await input.wait()

        if ringSeconds < 1 {
            await until(limit: .seconds(2), "no dropped frames reached t1") {
                (studio.liveTracks["t1"]?.droppedFrames ?? 0) > 0
            }
        } else {
            try await Task.sleep(for: .seconds(1))
            #expect(studio.liveTracks["t1"]?.droppedFrames == 0)
        }
        try await studio.stopRecording()

        #expect(((studio.lastTake?.droppedFrames["t1"]) ?? 0 > 0) == (ringSeconds < 1))
    }

    // MARK: Criterion 6

    @Test func theViewsSeeTheStart() async throws {
        let studio = try await studio(TestHAL([duo]))
        let changed = Flag()
        withObservationTracking {
            _ = studio.transport
            _ = studio.liveTracks
        } onChange: {
            changed.set()
        }

        try await studio.startRecording(armed: ["t1", "t2"], playhead: 0)

        await until(limit: .seconds(1), "no change reached the observer") { changed.value }
        try await studio.stopRecording()
    }

    /// Control: with no take, the observer is not called.
    @Test func withNoTakeTheViewsSeeNoChange() async throws {
        let studio = try await studio(TestHAL([duo]))
        let changed = Flag()
        withObservationTracking {
            _ = studio.transport
            _ = studio.liveTracks
        } onChange: {
            changed.set()
        }

        try await Task.sleep(for: .milliseconds(300))

        #expect(!changed.value)
    }
}

/// A flag that any thread can set.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool { lock.withLock { isSet } }
    func set() { lock.withLock { isSet = true } }
}
