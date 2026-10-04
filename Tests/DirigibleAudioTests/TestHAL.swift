import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

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
