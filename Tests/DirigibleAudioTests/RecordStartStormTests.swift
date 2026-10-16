import CoreAudio
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The longest time between two wakes of a main-actor task that sleeps 10 ms in a loop: a main
/// actor that a job holds wakes late. `late` has each time over 40 ms, with its end since the start.
@MainActor final class Heartbeat {
    private(set) var longest = Duration.zero
    private(set) var late: [(end: Duration, gap: Duration)] = []
    private var task: Task<Void, Never>?

    init() {
        let start = ContinuousClock.now
        task = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let now = ContinuousClock.now
                guard let self else { return }
                longest = max(longest, now - last)
                if now - last > .milliseconds(40) { late.append((now - start, now - last)) }
                last = now
            }
        }
    }

    func stop() -> Duration {
        task?.cancel()
        return longest
    }
}

/// A call app (for example Zoom in a call) that changes the devices at the take start. The main
/// actor stays free, the working track keeps its segments, and the window shows the state of the
/// failed track. Slow: the heartbeat is a wall-clock limit, so it runs only with no other suite
/// on the main actor. The tests run one at a time, so each heartbeat sees only its own test.
@MainActor @Suite(.serialized)
struct RecordStartStormTests {
    /// The limit of a wait for a Studio state, which a report hop sets on the main actor.
    let busy = Duration.seconds(20)
    /// The longest main-actor hold. macOS shows the busy cursor after about 2 s with no event
    /// handling; on a loaded machine, a storm gives gaps of up to about 100 ms with no hang.
    let holdLimit = Duration.milliseconds(500)
    let folder: TemporaryFolder
    let url: URL
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!
    let box = InputDevice(
        uid: "box", name: "Box", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!
    let wideBox = InputDevice(
        uid: "box", name: "Box", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [16],
        latency: 0)!

    /// One change of a call app at the take start. Each one leaves `box` without a working attach.
    enum Change: CaseIterable, Sendable {
        /// The start of `box` fails with `kAudioDevicePermissionsError` ('!hog') at each try.
        case busy
        /// `busy`, and 500 device-list events to each writer in 1 s.
        case busyListStorm
        /// `busyListStorm` with 16 channels on `box`: each attach try makes a 64 MiB ring.
        case busyWideListStorm
        /// `busy` with 20 ms for each attach try, and 500 device-list events to `box` at once,
        /// before the first-attach barrier of the start.
        case busySlowListBurst
        /// `box` leaves and comes back 500 times in 1 s, with a device-list event to each writer
        /// each time. It ends gone.
        case flapStorm
        /// `busy`, and 500 rate events and 500 layout events with no change to `mic` in 1 s.
        case formatStorm
    }

    /// Track `t1` on `mic` and track `t2` on `box`, both mono.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try session.setRoute(Route.device(uid: "box", channels: .mono(1)), track: "t2")
        try session.write(to: url)
    }

    /// Sends `count` events on a thread, one each `spacing`, and sets `done` after the last one.
    nonisolated static func storm(
        count: Int, spacing: Duration, done: OSAllocatedUnfairLock<Bool>, _ event: @escaping @Sendable (Int) -> Void
    ) {
        let thread = Thread {
            for index in 0..<count {
                event(index)
                if spacing > .zero { usleep(UInt32(spacing / .microseconds(1))) }
            }
            done.withLock { $0 = true }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"), arguments: Change.allCases)
    func aCallAppChangeAtTheTakeStartKeepsTheMainActorFree(change: Change) async throws {
        let hal = TestHAL([mic, change == .busyWideListStorm ? wideBox : box])
        if change != .flapStorm {
            hal.failAttach { uid, _ in uid == "box" ? .undone(kAudioDevicePermissionsError) : nil }
        }
        if change == .busySlowListBurst { hal.delayAttach("box", by: .milliseconds(20)) }
        let studio = try await Studio.open(url)
        studio.environment = .test(hal)
        let done = OSAllocatedUnfairLock(initialState: change == .busy)
        studio.environment.afterStart = { [weak studio] in
            guard let studio else { return }
            let writers = await MainActor.run { (studio.writer("mic"), studio.writer("box")) }
            guard let micWriter = writers.0, let boxWriter = writers.1 else { return }
            switch change {
            case .busy:
                return
            case .busyListStorm, .busyWideListStorm:
                Self.storm(count: 500, spacing: .milliseconds(2), done: done) { _ in
                    micWriter.post(.devicesChanged, from: nil)
                    boxWriter.post(.devicesChanged, from: nil)
                }
            case .busySlowListBurst:
                for _ in 0..<500 { boxWriter.post(.devicesChanged, from: nil) }
                done.withLock { $0 = true }
            case .flapStorm:
                Self.storm(count: 500, spacing: .milliseconds(2), done: done) { index in
                    hal.set("box", id: index.isMultiple(of: 2) || index == 499 ? nil : 2)
                    micWriter.post(.devicesChanged, from: nil)
                    boxWriter.post(.devicesChanged, from: nil)
                }
            case .formatStorm:
                Self.storm(count: 500, spacing: .milliseconds(2), done: done) { _ in
                    let current = hal.current("mic")
                    micWriter.post(.rate(48_000), from: current)
                    micWriter.post(.layout([1]), from: current)
                }
            }
        }
        let micInput = SyntheticInput(hal, "mic")
        var clock = DeviceClock(hostNanos: Double(takeStart) + 100_000_000)
        // Longer than the take: the detach at the stop ends the sends.
        micInput.play(clock.run(seconds: 30), pace: .realTime, takeStartIn: url)

        let heartbeat = Heartbeat()
        let watch = ContinuousClock.now
        try await studio.startRecording(armed: ["t1", "t2"], playhead: 0)
        let started = ContinuousClock.now - watch
        await until(limit: busy, "the storm did not end") { done.withLock { $0 } }
        await until(limit: busy, "t2 shows no lost state") { studio.liveTracks["t2"]?.state == .deviceLost }
        // The take records for 2 s after the start returns, so t1 has frames from after the storm.
        await until(limit: busy, "the take did not record 1 s after the storm") {
            ContinuousClock.now - watch >= started + .seconds(2)
        }
        let longest = heartbeat.stop()
        let t1State = studio.liveTracks["t1"]?.state
        let boxTries = hal.tries("box").count
        try await studio.stopRecording()
        await micInput.wait()

        let t1Lengths = studio.session.track("t1").map { $0.clips.map(\.length.count) } ?? []
        let t1Frames = t1Lengths.reduce(0, +)
        print(
            "R3 \(change): heartbeat longest \(longest), start returned after \(started), box attach tries "
                + "\(boxTries), t1 clips \(t1Lengths.count), t1 frames \(t1Frames), late \(heartbeat.late)")
        #expect(longest < holdLimit, "the main actor was held for \(longest)")
        #expect(t1State == .recording)
        #expect(studio.lastTake?.gaps == ["t2": .deviceLost])
        #expect(studio.lastTake?.droppedFrames["t1"] == nil)
        #expect(t1Frames >= 72_000, "t1 has \(t1Frames) frames")
    }

    /// The device-list listener hops to the main actor once for each call (`DeviceListListener`).
    /// 500 calls in 1 s with a read of 20 ms keep the main actor free.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aDeviceListStormKeepsTheMainActorFree() async throws {
        let list = DeviceList(read: {
            try? await Task.sleep(for: .milliseconds(20))
            return []
        })
        let done = OSAllocatedUnfairLock(initialState: false)
        let heartbeat = Heartbeat()
        Self.storm(count: 500, spacing: .milliseconds(2), done: done) { _ in
            Task { @MainActor in list.changed() }
        }
        await until(limit: busy, "the storm did not end") { done.withLock { $0 } }
        let longest = heartbeat.stop()

        print("R3 device-list storm: heartbeat longest \(longest), reads \(list.reads), late \(heartbeat.late)")
        #expect(longest < holdLimit, "the main actor was held for \(longest)")
    }
}

// MARK: C1, C2, C3 of record-start-hang

extension RecordStartStormTests {
    /// The two storms of R3 that held the start for 15 to 19 s: the start returns in under 1 s,
    /// the stop in under 2 s with a clip of `t1`, and `box` makes 6 tries or fewer. It prints the
    /// peak footprint of the test process (U11).
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"),
        arguments: [Change.busyWideListStorm, .busySlowListBurst])
    func aStormDoesNotDelayTheStartOrTheStop(change: Change) async throws {
        let hal = TestHAL([mic, change == .busyWideListStorm ? wideBox : box])
        hal.failAttach { uid, _ in uid == "box" ? .undone(kAudioDevicePermissionsError) : nil }
        if change == .busySlowListBurst { hal.delayAttach("box", by: .milliseconds(20)) }
        let studio = try await Studio.open(url)
        studio.environment = .test(hal)
        let done = OSAllocatedUnfairLock(initialState: false)
        studio.environment.afterStart = { [weak studio] in
            guard let studio else { return }
            let writers = await MainActor.run { (studio.writer("mic"), studio.writer("box")) }
            guard let micWriter = writers.0, let boxWriter = writers.1 else { return }
            if change == .busySlowListBurst {
                for _ in 0..<500 { boxWriter.post(.devicesChanged, from: nil) }
                done.withLock { $0 = true }
            } else {
                Self.storm(count: 500, spacing: .milliseconds(2), done: done) { _ in
                    micWriter.post(.devicesChanged, from: nil)
                    boxWriter.post(.devicesChanged, from: nil)
                }
            }
        }
        let micInput = SyntheticInput(hal, "mic")
        var clock = DeviceClock(hostNanos: Double(takeStart) + 100_000_000)
        micInput.play(clock.run(seconds: 30), pace: .realTime, takeStartIn: url)

        let watch = ContinuousClock.now
        try await studio.startRecording(armed: ["t1", "t2"], playhead: 0)
        let started = ContinuousClock.now - watch
        await until(limit: busy, "the storm did not end") { done.withLock { $0 } }
        // The take records for 2 s after the start returns, so t1 has frames from after the storm.
        await until(limit: busy, "the take did not record 2 s after the start") {
            ContinuousClock.now - watch >= started + .seconds(2)
        }
        let stopWatch = ContinuousClock.now
        try await studio.stopRecording()
        let stopped = ContinuousClock.now - stopWatch
        let boxTries = hal.tries("box").count
        await micInput.wait()

        print(
            "R3 fix \(change): start returned after \(started), stop after \(stopped), box attach tries \(boxTries), "
                + "peak footprint \(peakFootprint() / 1_048_576) MiB")
        #expect(started < .seconds(1), "the start returned after \(started)")
        #expect(stopped < .seconds(2), "the stop returned after \(stopped)")
        #expect(boxTries <= 6, "\(boxTries) attach tries of box")
        #expect(studio.session.track("t1")?.clips.isEmpty == false, "no clip of t1")
    }
}

/// The largest physical footprint of the process so far, in bytes (`ri_lifetime_max_phys_footprint`,
/// the ledger of `TASK_VM_INFO`). 0 when the read fails.
func peakFootprint() -> UInt64 {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return status == 0 ? info.ri_lifetime_max_phys_footprint : 0
}
