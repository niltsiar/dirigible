import CoreAudio
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

/// The test `DeviceHAL`: a device set that a test can change, the inputs of each attach, and
/// the producers that a clean detach stops. Object IDs start at 1 in the order of `devices`.
final class TestHAL: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [String: InputDevice] = [:]
    private var present: [String: (id: AudioObjectID, device: InputDevice)] = [:]
    private var tries: [String: [DeviceInput]] = [:]
    private var attached: [String: [DeviceInput]] = [:]
    private var capacities: [String: [Int]] = [:]
    private var detached: Set<ObjectIdentifier> = []
    private var producers: [String: [SyntheticInput]] = [:]
    private var detachResult = true
    private var failure: @Sendable (_ uid: String, _ try: Int) -> HALError? = { _, _ in nil }
    private var live: Set<String> = []
    private var gate: DispatchSemaphore?
    private var held = 0

    init(_ devices: [InputDevice]) {
        for (index, device) in devices.enumerated() {
            self.devices[device.uid] = device
            present[device.uid] = (AudioObjectID(index + 1), device)
        }
    }

    var hal: DeviceHAL {
        DeviceHAL(
            lookUp: { [self] uid in lookUp(uid) },
            attach: { [self] input throws(HALError) in try attach(input) },
            watchDevices: { _ in { true } })
    }

    /// A held lookup waits until `releaseLookUps`, with a limit of 10 s; after the limit it
    /// finds nothing. The limit is long, because a full suite can hold the main actor of the
    /// test for seconds.
    private func lookUp(_ uid: String) -> (id: AudioObjectID, device: InputDevice)? {
        if let gate = lock.withLock({ () -> DispatchSemaphore? in
            held += gate == nil ? 0 : 1
            return gate
        }) {
            guard gate.wait(timeout: .now() + 10) == .success else { return nil }
        }
        return lock.withLock { present[uid] }
    }

    private func attach(_ input: DeviceInput) throws(HALError) -> Detach {
        let (uid, error, live) = lock.withLock {
            let uid = present.first { $0.value.id == input.id }?.key ?? "id \(input.id)"
            tries[uid, default: []].append(input)
            return (uid, failure(uid, tries[uid]!.count), self.live.contains(uid))
        }
        if live { return try DeviceHAL.live.attach(input) }
        if let error { throw error }
        lock.withLock {
            attached[uid, default: []].append(input)
            capacities[uid, default: []].append(input.ring.capacity)
        }
        return { [self] in
            let (running, clean) = lock.withLock { (self.producers[uid] ?? [], detachResult) }
            guard clean else { return false }
            for producer in running { producer.stop(input) }
            lock.withLock { _ = detached.insert(ObjectIdentifier(input)) }
            return true
        }
    }

    /// Puts `device` in the set with object `id`, or takes the UID out with nil.
    func set(_ uid: String, id: AudioObjectID?, device: InputDevice? = nil) {
        lock.withLock {
            guard let id else {
                present[uid] = nil
                return
            }
            if let device { devices[uid] = device }
            present[uid] = (id, devices[uid]!)
        }
    }

    /// The next lookups wait until `releaseLookUps`.
    func holdLookUps() { lock.withLock { gate = DispatchSemaphore(value: 0) } }

    /// Lets the held lookups go on, and stops holding new ones.
    func releaseLookUps() {
        let (gate, count) = lock.withLock {
            defer { self.gate = nil }
            return (self.gate, held)
        }
        for _ in 0..<count { gate?.signal() }
    }

    /// The lookups that waited at the gate.
    var heldLookUps: Int { lock.withLock { held } }

    /// The detach result of the attaches after this call.
    func detach(returns result: Bool) { lock.withLock { detachResult = result } }

    /// The error of each attach call, from the UID and the 1-based count of its calls.
    func failAttach(_ rule: @escaping @Sendable (_ uid: String, _ try: Int) -> HALError?) {
        lock.withLock { failure = rule }
    }

    /// Attach calls for `uid` go to `DeviceHAL.live`.
    func attachLive(_ uid: String) { lock.withLock { _ = live.insert(uid) } }

    /// The inputs of each attach call of `uid`, also the calls that threw.
    func tries(_ uid: String) -> [DeviceInput] { lock.withLock { tries[uid] ?? [] } }

    /// The inputs of each successful attach of `uid`, in order.
    func inputs(_ uid: String) -> [DeviceInput] { lock.withLock { attached[uid] ?? [] } }

    /// The ring capacity of each successful attach of `uid`, read at the attach: a clean detach
    /// frees the ring.
    func capacities(_ uid: String) -> [Int] { lock.withLock { capacities[uid] ?? [] } }

    /// The last successful attach of `uid` that a clean detach did not end.
    func current(_ uid: String) -> DeviceInput? {
        lock.withLock { attached[uid]?.last.flatMap { detached.contains(ObjectIdentifier($0)) ? nil : $0 } }
    }

    func register(_ producer: SyntheticInput, for uid: String) {
        lock.withLock { producers[uid, default: []].append(producer) }
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
    /// The test HAL, a watchdog limit that other tests on the main actor cannot reach (also for
    /// the first record), the
    /// microphone access `access` (nil: authorized), `free` bytes (default 100 GB), and a disk
    /// check each 50 ms.
    static func test(
        _ hal: TestHAL, silenceLimit: Duration = .seconds(60), access: MicrophoneAccess? = nil,
        free: FreeBytes = FreeBytes()
    ) -> CaptureEnvironment {
        CaptureEnvironment(
            hal: hal.hal, silenceLimit: silenceLimit, firstRecordLimit: silenceLimit, microphoneAccess: { access },
            freeBytes: { _ in free.value }, diskCheckInterval: .milliseconds(50))
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
    /// The inputs that a clean detach ended: no thread sends into them again.
    private var stopped: Set<ObjectIdentifier> = []
    /// The threads that send now, and how many send into each input.
    private var sending = 0
    private var targets: [ObjectIdentifier: Int] = [:]

    init(_ hal: TestHAL, _ uid: String) {
        self.hal = hal
        self.uid = uid
        hal.register(self, for: uid)
    }

    private var isSending: Bool { lock.withLock { sending > 0 } }
    private func isStopped(_ input: DeviceInput) -> Bool { lock.withLock { stopped.contains(ObjectIdentifier(input)) } }

    /// Sends `records` into `input`, or into the input of attach number `attach` of the device,
    /// or into the current input. It waits for that attach, and then for `delay`: a device that
    /// is slow to start its IO.
    func play(
        _ records: [InputRecord], pace: Pace = .burst, flags: AudioTimeStampFlags = validTimes,
        into input: DeviceInput? = nil, attach: Int? = nil, delay: Duration = .zero
    ) {
        lock.withLock { sending += 1 }
        let thread = Thread { [self] in
            send(records, pace: pace, flags: flags, into: input, attach: attach, delay: delay)
            lock.withLock { sending -= 1 }
        }
        // A real IOProc runs on a real-time thread; a busy suite must not starve this one.
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Waits until the records of each `play` are sent, with a limit. It polls, so it does not
    /// hold the main actor.
    func wait(limit: Duration = .seconds(10)) async {
        let end = ContinuousClock.now + limit
        while isSending {
            guard ContinuousClock.now < end else {
                Issue.record("SyntheticInput \(uid) did not end in \(limit)")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Stops the sends into `input` and waits for them, with a limit of 1 s. The test detach
    /// calls it, so no thread writes into a ring after the writer frees it.
    func stop(_ input: DeviceInput) {
        let id = ObjectIdentifier(input)
        lock.withLock { _ = stopped.insert(id) }
        let end = Date.now + 1
        while lock.withLock({ targets[id, default: 0] > 0 }) {
            guard Date.now < end else {
                Issue.record("SyntheticInput \(uid) did not stop in 1 s")
                return
            }
            usleep(1000)
        }
    }

    private func send(
        _ records: [InputRecord], pace: Pace, flags: AudioTimeStampFlags, into target: DeviceInput?, attach: Int?,
        delay: Duration
    ) {
        let end = Date.now + 10
        func find() -> DeviceInput? {
            if let target { return target }
            guard let attach else { return hal.current(uid) }
            let inputs = hal.inputs(uid)
            return inputs.count >= attach ? inputs[attach - 1] : nil
        }
        var found = find()
        while found == nil, Date.now < end {
            usleep(1000)
            found = find()
        }
        if found != nil, delay > .zero { usleep(UInt32(delay / .microseconds(1))) }
        // The check and the count are one step, so a stop either sees this thread or ends it.
        guard let input = found,
            lock.withLock({ () -> Bool in
                let id = ObjectIdentifier(input)
                guard !stopped.contains(id) else { return false }
                targets[id, default: 0] += 1
                return true
            })
        else { return }
        defer { lock.withLock { targets[ObjectIdentifier(input), default: 1] -= 1 } }
        let start = Date.now
        for (index, record) in records.enumerated() {
            if isStopped(input) { return }
            if pace == .realTime {
                let delay = start.addingTimeInterval(Double(index) / 100).timeIntervalSinceNow
                if delay > 0 { usleep(UInt32(delay * 1e6)) }
            }
            input.ring.setRate(record.nominalRate)
            withIOProcArguments(record, flags: flags) { time, list in
                let full = Date.now
                while pace != .ignoreRoom, !input.ring.hasRoom(for: list) {
                    guard !isStopped(input), Date.now < full + 10 else { return }
                    usleep(500)
                }
                guard !isStopped(input) else { return }
                var output = AudioBufferList()
                _ = CaptureRing.ioProc(input.id, time, list, time, &output, time, input.ring.context)
            }
        }
    }
}
