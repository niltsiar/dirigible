import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The sample and host times of a HAL call that are valid.
let validTimes: AudioTimeStampFlags = [.sampleTimeValid, .hostTimeValid]

/// Makes the `AudioBufferList` and the `AudioTimeStamp` of one IOProc call from `record`. The
/// channel count of buffer `i` is `buffers[i].count / frameCount`.
func withIOProcArguments<Result>(
    _ record: InputRecord, flags: AudioTimeStampFlags = validTimes,
    _ body: (UnsafePointer<AudioTimeStamp>, UnsafePointer<AudioBufferList>) -> Result
) -> Result {
    let list = AudioBufferList.allocate(maximumBuffers: record.buffers.count)
    var data: [UnsafeMutablePointer<Float>] = []
    defer {
        for pointer in data { pointer.deallocate() }
        free(list.unsafeMutablePointer)
    }
    for (index, samples) in record.buffers.enumerated() {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(1, samples.count))
        pointer.initialize(from: samples, count: samples.count)
        data.append(pointer)
        list[index] = AudioBuffer(
            mNumberChannels: UInt32(samples.count / max(1, record.frameCount)),
            mDataByteSize: UInt32(samples.count * 4), mData: pointer)
    }
    var time = AudioTimeStamp()
    time.mSampleTime = record.sampleTime
    time.mHostTime = AudioConvertNanosToHostTime(record.hostTimeNanos)
    time.mRateScalar = 1
    time.mFlags = flags
    return body(&time, list.unsafePointer)
}

/// Calls `CaptureRing.ioProc` once, as the HAL does, after the rate listener effect.
func send(_ record: InputRecord, to ring: CaptureRing, flags: AudioTimeStampFlags = validTimes) {
    ring.setRate(record.nominalRate)
    withIOProcArguments(record, flags: flags) { time, list in
        var output = AudioBufferList()
        _ = CaptureRing.ioProc(1, time, list, time, &output, time, ring.context)
    }
}

/// The free bytes that the test environment gives. A test can change them during a take.
final class FreeBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64

    init(_ bytes: Int64 = 100_000_000_000) { self.bytes = bytes }

    var value: Int64 {
        get { lock.withLock { bytes } }
        set { lock.withLock { bytes = newValue } }
    }
}

extension CaptureEnvironment {
    /// The test HAL, `noWatchdog` as the watchdog limit (also for the first record), the
    /// microphone access `access` (nil: authorized), `free` bytes (default 100 GB), a disk
    /// check each 50 ms, the autosave step `saveSession` (default: the live write), a step
    /// before each finalize (default: none), and an offline Player.
    static func test(
        _ hal: TestHAL, silenceLimit: Duration = noWatchdog, access: MicrophoneAccess? = nil,
        free: FreeBytes = FreeBytes(),
        saveSession: @escaping @Sendable (Session, PackageLock) async throws(SessionFileError) -> URL = live
            .saveSession,
        beforeFinalize: @escaping @Sendable () async -> Void = {}
    ) -> CaptureEnvironment {
        CaptureEnvironment(
            hal: hal.hal, silenceLimit: silenceLimit, firstRecordLimit: silenceLimit, microphoneAccess: { access },
            freeBytes: { _ in free.value }, diskCheckInterval: .milliseconds(50), saveSession: saveSession,
            listenOutput: .offline(), beforeFinalize: beforeFinalize, playerOutput: .offline,
            beforeLookUp: { await hal.beforeLookUp() })
    }
}

/// A `Thread` that calls `CaptureRing.ioProc` with records, into the ring of the current input
/// of its device (`TestHAL.current`). It waits for an attach. Real-time pace sends one record each 10 ms; burst mode
/// sends as fast as the ring has room; `ignoreRoom` sends at once and lets a full ring drop.
final class SyntheticInput: @unchecked Sendable {
    enum Pace { case realTime, burst, ignoreRoom }

    let hal: TestHAL
    let uid: String
    private let lock = NSLock()
    /// The threads that send now, and how many send into each input.
    private var sending = 0
    private var targets: [ObjectIdentifier: Int] = [:]

    init(_ hal: TestHAL, _ uid: String) {
        self.hal = hal
        self.uid = uid
        hal.register(self, for: uid)
    }

    private var isSending: Bool { lock.withLock { sending > 0 } }

    /// Sends `records` into `input`, or into the input of attach number `attach` of the device,
    /// or into the current input. It waits for that attach, and then for `delay`: a device that
    /// is slow to start its IO. With `package`, the host times of `records` count from
    /// `takeStart`: after the attach, they move to the take start that `package` saved, so a
    /// late start of the take does not cut them. Then a miss of the attach in 30 s is an issue.
    /// With `hold`, the thread waits in that gate after it counts for its input and before the
    /// first record: a producer that a stop cannot end.
    func play(
        _ records: [InputRecord], pace: Pace = .burst, flags: AudioTimeStampFlags = validTimes,
        into input: DeviceInput? = nil, attach: Int? = nil, delay: Duration = .zero, takeStartIn package: URL? = nil,
        hold: Gate? = nil
    ) {
        lock.withLock { sending += 1 }
        let thread = Thread { [self] in
            send(
                records, pace: pace, flags: flags, into: input, attach: attach, delay: delay, takeStartIn: package,
                hold: hold)
            lock.withLock { sending -= 1 }
        }
        // A real IOProc runs on a real-time thread; a busy suite must not starve this one.
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Waits until the records of each `play` are sent, with a limit. It polls, so it does not
    /// hold the main actor. The limit and its wall cap (3 x the limit) count as in `poll`, and
    /// are longer than the attach wait of `takeStartIn`, so a miss shows as that issue. It is 3
    /// times the worst wait, 24.8 s (run test-pool-health, loops/s3q-12.log).
    func wait(limit: Duration = .seconds(75)) async {
        let watch = Stopwatch()
        defer { reportWait("SyntheticInput.wait", since: watch.start, "SyntheticInput \(uid)") }
        while isSending {
            guard watch.elapsed < limit, watch.wall < limit * 3 else {
                Issue.record("SyntheticInput \(uid) did not end in \(limit)")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits for the sends into `input` to stop, with a limit of 1 s. The test detach calls it
    /// after it marks `input` detached, so no thread writes into a ring after the writer frees
    /// it. False after the limit: a thread can still write, so the test detach fails and the
    /// writer keeps the ring. It records no issue: it runs on the writer queue, so the issue
    /// belongs to no test.
    func stop(_ input: DeviceInput) -> Bool {
        let id = ObjectIdentifier(input)
        let end = Date.now + 1
        while lock.withLock({ targets[id, default: 0] > 0 }) {
            guard Date.now < end else {
                FileHandle.standardError.write(Data("SyntheticInput \(uid) did not stop in 1 s\n".utf8))
                return false
            }
            usleep(1000)
        }
        return true
    }

    /// Calls `find` each 1 ms until it gives a value; nil after `limit`. As in `until`, the limit
    /// counts the time of a `Stopwatch`: a take start that waits behind a main-actor hold of other
    /// suites does not use it up. `cap` (default 3 x `limit`) is the longest wait in wall time.
    static func poll<Value>(limit: Duration, cap: Duration? = nil, _ find: () -> Value?) -> Value? {
        let watch = Stopwatch()
        let cap = cap ?? limit * 3
        var found = find()
        while found == nil, watch.elapsed < limit, watch.wall < cap {
            usleep(1000)
            found = find()
        }
        return found
    }

    private func send(
        _ records: [InputRecord], pace: Pace, flags: AudioTimeStampFlags, into target: DeviceInput?, attach: Int?,
        delay: Duration, takeStartIn package: URL?, hold: Gate?
    ) {
        let found = Self.poll(limit: .seconds(package == nil ? 10 : 30)) { () -> DeviceInput? in
            if let target { return target }
            guard let attach else { return hal.current(uid) }
            let inputs = hal.inputs(uid)
            return inputs.count >= attach ? inputs[attach - 1] : nil
        }
        var records = records
        if let package {
            guard found != nil else {
                Issue.record("SyntheticInput \(uid) did not attach in 30 s")
                return
            }
            guard let saved = (try? Session(contentsOf: package))?.recording?.takeStartHostTimeNanos else {
                Issue.record("SyntheticInput \(uid) found no saved take start")
                return
            }
            // The operators wrap: a record can be before `takeStart`, and `saved` is less than
            // `takeStart` (1000 s) when the Mac booted less than 1000 s ago. The sum is in range.
            records = records.map {
                InputRecord(
                    sampleTime: $0.sampleTime, hostTimeNanos: $0.hostTimeNanos &- takeStart &+ saved,
                    frameCount: $0.frameCount, nominalRate: $0.nominalRate, buffers: $0.buffers)!
            }
        }
        if found != nil, delay > .zero { usleep(UInt32(delay / .microseconds(1))) }
        // The check and the count are one step, so a stop either sees this thread or ends it.
        // The check reads the detached set of the HAL, so it covers each producer, also one
        // that a detach did not list.
        guard let input = found,
            lock.withLock({ () -> Bool in
                guard !hal.isDetached(input) else { return false }
                targets[ObjectIdentifier(input), default: 0] += 1
                return true
            })
        else { return }
        defer { lock.withLock { targets[ObjectIdentifier(input), default: 1] -= 1 } }
        hold?.waitOnce()
        let start = Date.now
        for (index, record) in records.enumerated() {
            if hal.isDetached(input) { return }
            if pace == .realTime {
                let delay = start.addingTimeInterval(Double(index) / 100).timeIntervalSinceNow
                if delay > 0 { usleep(UInt32(delay * 1e6)) }
            }
            input.ring.setRate(record.nominalRate)
            withIOProcArguments(record, flags: flags) { time, list in
                let full = Date.now
                while pace != .ignoreRoom, !input.ring.hasRoom(for: list) {
                    guard !hal.isDetached(input), Date.now < full + 10 else { return }
                    usleep(500)
                }
                guard !hal.isDetached(input) else { return }
                var output = AudioBufferList()
                _ = CaptureRing.ioProc(input.id, time, list, time, &output, time, input.ring.context)
            }
        }
    }
}
