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
    private var holding = false
    private var held = 0
    private var attachGate: DispatchSemaphore?
    private var detachGate: Gate?
    private var log: [String: [Event]] = [:]
    // App sources (decision 0030): the found app of each bundle ID, its name, the tap layout,
    // the aggregate of each tap, and the HAL calls in order.
    private var apps: [String: AppFound] = [:]
    private var names: [String: String] = [:]
    private var tapLayouts: [String: [Int]] = [:]
    private var aggregates: [AudioObjectID: String] = [:]
    private var nextAggregate = AudioObjectID(1000)
    private var failingTeardown: String?
    private var attachDelays: [String: Duration] = [:]
    private var callLog: [String] = []
    private var tapGate: DispatchSemaphore?
    /// The output devices that left the device list (`deviceExists` is false for them).
    private var goneDevices: Set<String> = []

    /// A successful attach or a clean detach of one input.
    enum Event: Equatable {
        case attach(DeviceInput)
        case detach(DeviceInput)

        static func == (a: Event, b: Event) -> Bool {
            switch (a, b) {
            case (.attach(let x), .attach(let y)), (.detach(let x), .detach(let y)): x === y
            default: false
            }
        }
    }

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
            watchDevices: { _ in { true } },
            lookUpApp: { [self] bundleID, _ in
                lock.withLock {
                    callLog.append("lookUpApp \(bundleID)")
                    return apps[bundleID]
                }
            },
            makeTap: { [self] found in makeTap(found) },
            appName: { [self] bundleID in lock.withLock { names[bundleID] ?? bundleID } },
            deviceExists: { [self] uid in lock.withLock { !goneDevices.contains(uid) } })
    }

    /// A tap aggregate with the facts of `found`, or of its tap layout, and a teardown that logs
    /// its two steps. With `failTeardown("aggregate")` they return an error; every step runs.
    private func makeTap(_ found: AppFound) -> (id: AudioObjectID, device: InputDevice, teardown: Detach) {
        // A held tap waits as an attach waits while the System Audio Recording prompt shows.
        if let gate = lock.withLock({ tapGate }), gate.wait(timeout: .now() + 30) == .timedOut {
            Issue.record("A held tap was not released in 30 s")
        }
        let uid = found.device.uid
        let (id, layout) = lock.withLock {
            nextAggregate += 1
            aggregates[nextAggregate] = uid
            callLog.append("makeTap \(uid)")
            return (nextAggregate, tapLayouts[uid] ?? found.device.channelsPerBuffer)
        }
        let device = InputDevice(
            uid: "com.delineas.dirigible.tap.\(id)", name: "Tap", nominalRate: found.device.nominalRate,
            availableRates: found.device.availableRates, channelsPerBuffer: layout, latency: found.device.latency)!
        let teardown: Detach = { [self] in
            lock.withLock {
                callLog.append("destroyAggregate \(uid)")
                callLog.append("destroyTap \(uid)")
                return failingTeardown != "aggregate" && failingTeardown != "tap"
            }
        }
        return (id, device, teardown)
    }

    private func lookUp(_ uid: String) -> (id: AudioObjectID, device: InputDevice)? {
        lock.withLock { present[uid] }
    }

    /// The step before the lookup of a take start (`CaptureEnvironment.beforeLookUp`): a held
    /// start suspends here until `releaseLookUps`. It polls, so it blocks no thread of the pool.
    /// The old hold was a 10 s semaphore wait that then found no device, and a full suite can
    /// hold the main actor of the test past 10 s (deviceMissing in make check). The limit is
    /// under the time of one full suite, and it records a failure, never a missing device. It
    /// stays 60 s: the hold prints no `WAIT` line, so the loops of run test-pool-health have no
    /// wait for it.
    func beforeLookUp() async {
        guard
            lock.withLock({ () -> Bool in
                held += holding ? 1 : 0
                return holding
            })
        else { return }
        let limit = Duration.seconds(60)
        let end = ContinuousClock.now + limit
        while lock.withLock({ holding }) {
            guard ContinuousClock.now < end else {
                Issue.record("A held lookup was not released in \(limit)")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func attach(_ input: DeviceInput) throws(HALError) -> Detach {
        if let gate = lock.withLock({ attachGate }), gate.wait(timeout: .now() + 30) == .timedOut {
            Issue.record("A held attach was not released in 30 s")
        }
        let delay = lock.withLock {
            attachDelays[present.first { $0.value.id == input.id }?.key ?? aggregates[input.id] ?? ""] ?? .zero
        }
        if delay > .zero { usleep(UInt32(delay / .microseconds(1))) }
        let (uid, error, live) = lock.withLock {
            let uid = present.first { $0.value.id == input.id }?.key ?? aggregates[input.id] ?? "id \(input.id)"
            tries[uid, default: []].append(input)
            return (uid, failure(uid, tries[uid]!.count), self.live.contains(uid))
        }
        if live { return try DeviceHAL.live.attach(input) }
        if let error { throw error }
        lock.withLock {
            callLog.append("attach \(uid)")
            attached[uid, default: []].append(input)
            capacities[uid, default: []].append(input.ring.capacity)
            log[uid, default: []].append(.attach(input))
        }
        return { [self] in
            lock.withLock { detachGate }?.waitOnce()
            let (running, clean) = lock.withLock {
                callLog.append("detach \(uid)")
                return (self.producers[uid] ?? [], detachResult && failingTeardown != "detach")
            }
            guard clean else { return false }
            for producer in running { producer.stop(input) }
            lock.withLock {
                detached.insert(ObjectIdentifier(input))
                log[uid, default: []].append(.detach(input))
            }
            return true
        }
    }

    /// The app that `lookUpApp` finds for `bundleID` (nil: no output device), and its name.
    func setApp(_ bundleID: String, _ found: AppFound?, name: String? = nil) {
        lock.withLock {
            apps[bundleID] = found
            if let name { names[bundleID] = name }
        }
    }

    /// The input layout of the next tap aggregates of `uid` (`app:<bundle ID>`), for example a
    /// headset microphone before the tap stream (probe P13).
    func setTapLayout(_ uid: String, _ layout: [Int]) { lock.withLock { tapLayouts[uid] = layout } }

    /// The teardown step that fails from now on: "detach" (the IOProc and the listeners) or
    /// "aggregate" or "tap" (the destroy of the tap aggregate or of the tap). Nil: every step returns noErr.
    func failTeardown(_ step: String?) { lock.withLock { failingTeardown = step } }

    /// Takes the output device `uid` out of the device list.
    func removeOutput(_ uid: String) { lock.withLock { _ = goneDevices.insert(uid) } }

    /// The next taps wait until `releaseTaps`, with a limit of 30 s: the prompt of a first take.
    func holdTaps() { lock.withLock { tapGate = DispatchSemaphore(value: 0) } }

    /// Lets the held taps go on, and stops holding new ones.
    func releaseTaps() {
        let gate = lock.withLock {
            defer { tapGate = nil }
            return tapGate
        }
        for _ in 0..<8 { gate?.signal() }
    }

    /// Each attach of `uid` waits `delay` first: a device that is slow to start.
    func delayAttach(_ uid: String, by delay: Duration) { lock.withLock { attachDelays[uid] = delay } }

    /// The app lookups, the taps, the successful attaches, the detaches, and the teardown steps,
    /// in order.
    var calls: [String] { lock.withLock { callLog } }

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

    /// The next take starts wait before their lookup until `releaseLookUps`.
    func holdLookUps() { lock.withLock { holding = true } }

    /// Lets the held starts go on, and stops holding new ones.
    func releaseLookUps() { lock.withLock { holding = false } }

    /// The next attaches wait until `releaseAttaches`, with a limit of 30 s.
    func holdAttaches() { lock.withLock { attachGate = DispatchSemaphore(value: 0) } }

    /// Lets the held attaches go on, and stops holding new ones.
    func releaseAttaches() {
        let gate = lock.withLock {
            defer { attachGate = nil }
            return attachGate
        }
        // More signals than waiters do no harm: the gate is not used again.
        for _ in 0..<8 { gate?.signal() }
    }

    /// The next detach waits in `gate` (`Gate.waitOnce`) before it runs.
    func holdNextDetach(in gate: Gate) { lock.withLock { detachGate = gate } }

    /// Each successful attach and each clean detach of `uid`, in order.
    func events(_ uid: String) -> [Event] { lock.withLock { log[uid] ?? [] } }

    /// The take starts that waited before their lookup.
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
    /// microphone access `access` (nil: authorized), `free` bytes (default 100 GB), a disk
    /// check each 50 ms, the autosave step `saveSession` (default: the live write), a step
    /// before each finalize (default: none), and an offline Player.
    static func test(
        _ hal: TestHAL, silenceLimit: Duration = .seconds(60), access: MicrophoneAccess? = nil,
        free: FreeBytes = FreeBytes(),
        saveSession: @escaping @Sendable (Session, PackageLock) async throws(SessionFileError) -> URL = live
            .saveSession,
        beforeFinalize: @escaping @Sendable () async -> Void = {}
    ) -> CaptureEnvironment {
        CaptureEnvironment(
            hal: hal.hal, silenceLimit: silenceLimit, firstRecordLimit: silenceLimit, microphoneAccess: { access },
            freeBytes: { _ in free.value }, diskCheckInterval: .milliseconds(50), saveSession: saveSession,
            beforeFinalize: beforeFinalize, playerOutput: .offline, beforeLookUp: { await hal.beforeLookUp() })
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
    /// is slow to start its IO. With `package`, the host times of `records` count from
    /// `takeStart`: after the attach, they move to the take start that `package` saved, so a
    /// late start of the take does not cut them. Then a miss of the attach in 30 s is an issue.
    func play(
        _ records: [InputRecord], pace: Pace = .burst, flags: AudioTimeStampFlags = validTimes,
        into input: DeviceInput? = nil, attach: Int? = nil, delay: Duration = .zero, takeStartIn package: URL? = nil
    ) {
        lock.withLock { sending += 1 }
        let thread = Thread { [self] in
            send(records, pace: pace, flags: flags, into: input, attach: attach, delay: delay, takeStartIn: package)
            lock.withLock { sending -= 1 }
        }
        // A real IOProc runs on a real-time thread; a busy suite must not starve this one.
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Waits until the records of each `play` are sent, with a limit. It polls, so it does not
    /// hold the main actor. The limit is longer than the attach wait of `takeStartIn`, so a
    /// miss shows as that issue. It is 3 times the worst wait, 24.8 s (run test-pool-health,
    /// loops/s3q-12.log).
    func wait(limit: Duration = .seconds(75)) async {
        let start = ContinuousClock.now
        defer { reportWait("SyntheticInput.wait", since: start, "SyntheticInput \(uid)") }
        let end = start + limit
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
        delay: Duration, takeStartIn package: URL?
    ) {
        let end = Date.now + (package == nil ? 10 : 30)
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
