import Atomics
import DirigibleCore
import Foundation

/// A device fact for the studio: the state of one track of a take. `status` is the raw OSStatus
/// or errno of a write error, for tests. It never reaches the public API.
struct Report: Sendable {
    let take: Int
    let arm: Int
    let state: LiveTrack.State
    let status: Int32?
}

/// The recorder of one device for the whole take (decisions 0004 and 0013). A drain timer on its
/// serial queue pops the ring of the current `DeviceInput`, runs the watchdog while the device
/// runs, and tries to attach again each 1 s while it is lost. `TrackSegments` writes the records
/// to the segment files of the tracks. All state is confined to its serial queue, so it is
/// `@unchecked Sendable`.
final class DeviceWriter: @unchecked Sendable {
    enum Event: Sendable {
        case rate(Double)
        /// The channel count of each input buffer.
        case layout([Int])
        case alive(Bool)
        case devicesChanged
    }

    private enum Phase { case ready, running, lost, finished }

    /// A writer with this many kept inputs attaches no more in the take (decision 0013).
    static let keptLimit = 8
    static let retryInterval = Duration.seconds(1)

    private let take: Int
    private let hal: DeviceHAL
    private let report: @Sendable (Report) -> Void
    private let drainInterval: Duration
    private let silenceLimit: Duration
    private let ringSeconds: Double
    private let queue: DispatchQueue
    private var tracks: TrackSegments
    private var phase = Phase.ready
    /// The attached appearance of the device and its detach.
    private var input: (input: DeviceInput, detach: Detach)?
    /// Inputs whose detach failed: a late call can still use their rings, so they stay.
    private var kept: [DeviceInput] = []
    /// The ring of an attach that threw with no IOProc left: no call can reach it.
    private var spare: CaptureRing?
    private var unwatch: Detach?
    private var timer: DispatchSourceTimer?
    /// The watchdog clock: the last valid record, or the attach.
    private var lastValid = ContinuousClock.now
    /// The retry clock: the loss, or the last try.
    private var lastTry = ContinuousClock.now
    private let dropped = ManagedAtomic<Int>(0)
    private var endHostNanos = UInt64.max

    /// `tracks` holds the arm index and the 1-based device channels of each track. The start
    /// checks of `Studio` make every channel exist on the device. `drainInterval`,
    /// `silenceLimit`, and `ringSeconds` are parameters so that tests stay fast.
    init(
        device: InputDevice, tracks: [(arm: Int, channels: Route.Channels)], take: Int, folder: URL, hal: DeviceHAL,
        report: @escaping @Sendable (Report) -> Void = { _ in }, drainInterval: Duration = .milliseconds(50),
        silenceLimit: Duration = .seconds(2), ringSeconds: Double = 10
    ) {
        self.take = take
        self.hal = hal
        self.report = report
        self.drainInterval = drainInterval
        self.silenceLimit = silenceLimit
        self.ringSeconds = ringSeconds
        queue = DispatchQueue(label: "Dirigible.DeviceWriter.\(device.uid)")
        self.tracks = TrackSegments(device: device, tracks: tracks, take: take, folder: folder, report: report)
    }

    deinit { timer?.cancel() }

    /// The dropped frames of the take. Any thread can read it.
    var droppedFrames: Int { dropped.load(ordering: .relaxed) }

    /// Starts the drain timer and the device-list listener, and attaches. A failed attach makes
    /// the device lost, and the retry goes on.
    func start() {
        queue.async { [self] in
            guard phase == .ready else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let nanos = Int(drainInterval / .nanoseconds(1))
            timer.schedule(
                deadline: .now() + .nanoseconds(nanos), repeating: .nanoseconds(nanos), leeway: .nanoseconds(0))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            unwatch = hal.watchDevices(self)
            if !attach() { lose() }
        }
    }

    /// A device listener passes its own `DeviceInput`; the device-list listener passes nil. A
    /// rate, layout, or IsAlive event from an input that is not the current one does nothing.
    func post(_ event: Event, from sender: DeviceInput?) {
        queue.async { [self] in handle(event, from: sender) }
    }

    /// Detaches, writes the rest of the ring, closes every segment, and ends the timer. Returns
    /// the gaps of the take. A second call returns the same gaps.
    @discardableResult
    func finish() async -> [Int: LiveTrack.State] {
        await withCheckedContinuation { (done: CheckedContinuation<[Int: LiveTrack.State], Never>) in
            queue.async { [self] in
                if phase != .finished {
                    detach()
                    tracks.endSegment()
                    _ = unwatch?()
                    spare?.deallocate()
                    spare = nil
                    timer?.cancel()
                    phase = .finished
                }
                done.resume(returning: tracks.gaps)
            }
        }
    }

    /// The writer writes no record that starts at or after `end` (host time), so a timed take
    /// does not grow while the stop waits for the queue. Such a record still restarts the
    /// watchdog clock.
    func end(atHostNanos end: UInt64) {
        queue.async { [self] in endHostNanos = end }
    }

    /// The WAV bytes of the take so far, for the disk rule.
    func wavBytes() async -> Int64 {
        await withCheckedContinuation { done in queue.async { [self] in done.resume(returning: tracks.wavBytes) } }
    }

    private func handle(_ event: Event, from sender: DeviceInput?) {
        guard phase == .running || phase == .lost else { return }
        if case .devicesChanged = event {
            if phase == .running, hal.lookUp(tracks.device.uid)?.id != input?.input.id { lose() }
            return comeBack()
        }
        guard let current = input?.input, current === sender else { return }
        switch event {
        case .layout(let channels):
            // The records in the ring that do not match the new layout end the segment.
            tracks.endSegment()
            let device = tracks.device
            let changed = InputDevice(
                uid: device.uid, name: device.name, nominalRate: device.nominalRate,
                availableRates: device.availableRates, channelsPerBuffer: channels, latency: device.latency)
            if let changed, tracks.hasRoutedChannels(changed) { tracks.use(changed) } else { lose() }
        case .alive(false):
            lose()
        case .rate, .alive(true), .devicesChanged:
            // The rate is in the ring already: the next record header breaks the segment.
            break
        }
    }

    private func tick() {
        drain()
        let now = ContinuousClock.now
        if phase == .running, now - lastValid >= silenceLimit {
            lose()
        } else if phase == .lost, now - lastTry >= Self.retryInterval {
            comeBack()
        }
    }

    /// Writes each record that is in the ring when the drain starts, so an event that a listener
    /// posts during a drain acts before the records that come after it. A record without valid
    /// times ends the segment, and only a valid record restarts the watchdog clock.
    private func drain() {
        guard phase != .finished, let ring = input?.input.ring else { return }
        let end = ring.end()
        while let popped = ring.pop(before: end) {
            guard let record = popped.record else {
                tracks.endSegment()
                continue
            }
            if record.hostTimeNanos < endHostNanos { tracks.write(record) }
            lastValid = .now
        }
        dropped.wrappingIncrement(by: ring.takeDroppedFrames(), ordering: .relaxed)
    }

    /// Detaches the current input and writes the rest of its ring. A clean detach frees the
    /// ring; a failed one keeps the input.
    private func detach() {
        guard let (current, detach) = input else { return }
        let clean = detach()
        drain()
        if clean { current.ring.deallocate() } else { kept.append(current) }
        input = nil
    }

    /// Running or ready to lost: detach, end the segments, report, and record the gaps.
    private func lose() {
        detach()
        tracks.endSegment()
        phase = .lost
        lastTry = .now
        for arm in tracks.arms {
            tracks.gaps[arm] = tracks.gaps[arm] ?? .deviceLost
            report(Report(take: take, arm: arm, state: .deviceLost, status: nil))
        }
    }

    /// Lost to running when the device is present with the routed channels and attaches.
    private func comeBack() {
        guard phase == .lost else { return }
        lastTry = .now
        guard attach() else { return }
        for arm in tracks.arms { report(Report(take: take, arm: arm, state: .recording, status: nil)) }
    }

    /// A new `DeviceInput` for the device as the lookup finds it now. The routed channels are
    /// checked before a ring exists, and a ring of an attach that threw is used again.
    private func attach() -> Bool {
        guard kept.count < Self.keptLimit, let found = hal.lookUp(tracks.device.uid),
            tracks.hasRoutedChannels(found.device)
        else { return false }
        tracks.use(found.device)
        let capacity = CaptureRing.capacity(for: found.device, seconds: ringSeconds)
        if let spare, spare.capacity != capacity {
            spare.deallocate()
            self.spare = nil
        }
        let ring = spare ?? CaptureRing(capacity: capacity, rate: found.device.nominalRate)
        spare = nil
        ring.setRate(found.device.nominalRate)
        let input = DeviceInput(id: found.id, ring: ring, writer: self)
        do throws(HALError) {
            self.input = (input, try hal.attach(input))
        } catch .undoFailed {
            kept.append(input)
            return false
        } catch {
            spare = ring
            return false
        }
        phase = .running
        lastValid = .now
        return true
    }
}
