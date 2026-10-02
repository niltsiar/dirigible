import Atomics
import CoreAudio
import DirigibleCore
import Foundation

/// The recorder of one device for the whole take (decisions 0004 and 0013). A drain timer on its
/// serial queue pops the ring of the current `DeviceInput`, runs the watchdog while the device
/// runs, and tries to attach again each 1 s while it is lost. `TrackSegments` writes the records
/// to the segment files of the tracks. A writer with no take files is a monitor (decision 0015):
/// it computes the peaks and writes no file. All state is confined to its serial queue, so it is
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

    /// A writer with this many failed detaches attaches no more in the take (decision 0013).
    static let failedDetachLimit = 8
    static let retryInterval = Duration.seconds(1)

    private let hal: DeviceHAL
    /// The bundle ID of an app source (decision 0030), else nil. An app writer makes a tap and
    /// its aggregate at each attach, and the detach tears both down.
    let app: String?
    private let report: @Sendable (Report) -> Void
    private let drainInterval: Duration
    private let silenceLimit: Duration
    private let firstRecordLimit: Duration
    private let ringSeconds: Double
    /// At this many kept inputs, the writer attaches no more (decision 0015).
    private let keepLimit: Int
    private let queue: DispatchQueue
    private var tracks: TrackSegments
    private var phase = Phase.ready
    /// The attached appearance of the device, its detach, and for an app the key of the
    /// appearance: its processes and the main sub-device of its aggregate (decision 0030).
    private var input: (input: DeviceInput, detach: Detach, key: AppKey?)?
    /// The detaches that failed: a late IOProc call can still use their ring bytes.
    private var failedDetaches = 0
    /// The inputs that `keep` kept for the process life.
    private var kept = 0
    /// True after the writer reported `.retryStopped`.
    private var retryStopped = false
    /// The last running state that an app writer reported: `.waitingForApp` while its app has no
    /// process, else `.recording`.
    private var appState = LiveTrack.State.recording
    /// The silence check of an app track for the take (A9).
    private var silence = SilenceCheck()
    /// The ring of an attach that threw before its IOProc existed: no call can reach it.
    private var spare: CaptureRing?
    private var unwatch: Detach?
    private var timer: DispatchSourceTimer?
    /// The watchdog clock: the last valid record, or the attach.
    private var lastValid = ContinuousClock.now
    /// True after the first valid record of the current appearance. Before it, the watchdog
    /// uses `firstRecordLimit`.
    private var hasRecord = false
    /// The retry clock: the loss, or the last try.
    private var lastTry = ContinuousClock.now
    private let dropped = ManagedAtomic<Int>(0)
    /// `tracks.wavBytes` after each drain.
    private let wavByteCount = ManagedAtomic<Int64>(0)
    private var endHostNanos = UInt64.max

    /// `tracks` holds the arm index and the 1-based device channels of each track. The start
    /// checks of `Studio` make every channel exist on the device. `files` is nil for a monitor,
    /// which reports take 0 (`tracks.take`). `drainInterval`,
    /// `silenceLimit`, `firstRecordLimit`, and `ringSeconds` are parameters so that tests stay
    /// fast. `app` is the bundle ID of an app source; then `device` has the UID
    /// `app:<bundle ID>` and the app name.
    init(
        device: InputDevice, tracks: [(arm: Int, channels: Route.Channels)], files: TakeFiles?, hal: DeviceHAL,
        report: @escaping @Sendable (Report) -> Void = { _ in }, drainInterval: Duration = .milliseconds(50),
        silenceLimit: Duration = .seconds(2), firstRecordLimit: Duration = .seconds(10), ringSeconds: Double = 10,
        keepLimit: Int = .max, app: String? = nil
    ) {
        self.hal = hal
        self.app = app
        self.report = report
        self.drainInterval = drainInterval
        self.silenceLimit = silenceLimit
        self.firstRecordLimit = firstRecordLimit
        self.ringSeconds = ringSeconds
        self.keepLimit = keepLimit
        queue = DispatchQueue(label: "Dirigible.DeviceWriter.\(device.uid)")
        self.tracks = TrackSegments(
            device: device, tracks: tracks, files: files, report: report, routesLastChannels: app != nil)
    }

    deinit { timer?.cancel() }

    /// The frames of the take that the ring or the writer dropped: a full ring, a record without
    /// valid times, and a record with no routed channel or a wrong size. Any thread can read it.
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
            if attach() { reportAppState() } else { lose() }
        }
    }

    /// Returns after the first attach try of `start()`: a barrier on the queue.
    func started() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    }

    /// A device listener passes its own `DeviceInput`; the device-list listener passes nil. A
    /// rate, layout, or IsAlive event from an input that is not the current one does nothing.
    func post(_ event: Event, from sender: DeviceInput?) {
        queue.async { [self] in handle(event, from: sender) }
    }

    /// Detaches, writes the rest of the ring, closes every segment, and ends the timer. Returns
    /// the gaps of the take. A second call returns the same gaps.
    @discardableResult
    func finish() async -> [Int: TakeResult.Gap] {
        await withCheckedContinuation { (done: CheckedContinuation<[Int: TakeResult.Gap], Never>) in
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
        queue.async { [self] in endHostNanos = min(endHostNanos, end) }
    }

    /// The app name when the silence warning showed and no sound came in the take (A9), else nil.
    func silentApp() async -> String? {
        await withCheckedContinuation { done in
            queue.async { [self] in done.resume(returning: silence.warns ? tracks.device.name : nil) }
        }
    }

    /// The WAV bytes of the take so far, for the disk rule.
    /// Any thread reads it with no queue hop, so a writer that waits (an app attach at the prompt,
    /// E1) never holds the disk watch.
    var wavBytes: Int64 { wavByteCount.load(ordering: .relaxed) }

    private func handle(_ event: Event, from sender: DeviceInput?) {
        guard phase == .running || phase == .lost else { return }
        if case .devicesChanged = event {
            if phase == .running, app != nil { return appChanged() }
            if phase == .running, hal.lookUp(tracks.device.uid)?.id != input?.input.id { lose() }
            return comeBack()
        }
        guard let current = input?.input, current === sender else { return }
        switch event {
        case .layout(let channels):
            // A record in the ring of the other layout ends the segment again and re-routes.
            tracks.endSegment()
            guard tracks.use(channels: channels) else { return lose() }
            growRing(rate: tracks.device.nominalRate, channels: tracks.device.channelCount)
        case .rate(let rate):
            // The rate is in the ring already: the next record header breaks the segment.
            growRing(rate: rate, channels: tracks.device.channelCount)
        case .alive(false):
            // A8: an app aggregate rebuilds on the new output; a device is lost.
            if app != nil { rebuild() } else { lose() }
        case .alive(true), .devicesChanged:
            break
        }
    }

    /// A rate or a layout that needs a larger ring starts a new appearance, so the IO thread
    /// never writes into a ring that is too small or touches a new page. A failed attach makes
    /// the device lost.
    private func growRing(rate: Double, channels: Int) {
        guard let current = input?.input,
            CaptureRing.capacity(rate: rate, channels: channels, seconds: ringSeconds) > current.ring.capacity
        else { return }
        detach()
        if !attach() { lose() }
    }

    private func tick() {
        drain()
        if app != nil, phase == .running { checkSilence() }
        let now = ContinuousClock.now
        if phase == .running, now - lastValid >= (hasRecord ? silenceLimit : firstRecordLimit) {
            lose()
        } else if phase == .lost, now - lastTry >= Self.retryInterval {
            comeBack()
        }
    }

    /// Writes each record that is in the ring when the drain starts, so an event that a listener
    /// posts during a drain acts before the records that come after it. A record without valid
    /// times ends the segment, and only a valid record restarts the watchdog clock. Each record
    /// is written or counted as dropped.
    private func drain() {
        guard phase != .finished, let ring = input?.input.ring else { return }
        let end = ring.end()
        var lost = ring.takeDroppedFrames()
        var hosts: (first: UInt64, last: UInt64)?
        while let popped = ring.pop(before: end) {
            guard let record = popped.record else {
                tracks.endSegment()
                lost += popped.frames
                continue
            }
            if record.hostTimeNanos < endHostNanos, !tracks.write(record) { lost += record.frameCount }
            lastValid = .now
            hasRecord = true
            hosts = (hosts?.first ?? record.hostTimeNanos, record.hostTimeNanos)
        }
        dropped.wrappingIncrement(by: lost, ordering: .relaxed)
        wavByteCount.store(tracks.wavBytes, ordering: .relaxed)
        let levels = tracks.takeLevels()
        if app != nil, let hosts {
            silence.take(
                firstHost: hosts.first, lastHost: hosts.last, heard: levels.values.contains { $0.peak > 0 },
                hasProcess: input?.key?.processes.isEmpty == false)
        }
        report(
            .levels(take: tracks.take, arms: levels, latencyNanos: tracks.latencyNanos, droppedFrames: droppedFrames))
    }

    /// Detaches the current input and writes the rest of its ring, then keeps the input.
    private func detach() {
        guard let (current, detach, _) = input else { return }
        let clean = detach()
        drain()
        keep(current, clean: clean)
        input = nil
    }

    /// Keeps `input` and its ring atomics for the process life (decision 0013): a listener call
    /// that was in progress during its removal can use them at any later time, also after the
    /// take. A clean detach frees the ring bytes, because no IOProc call can come.
    private func keep(_ input: DeviceInput, clean: Bool) {
        _ = Unmanaged.passRetained(input)
        kept += 1
        if clean { input.ring.deallocateBytes() } else { failedDetaches += 1 }
    }

    /// Running or ready to lost: detach, end the segments, report, and record the gaps. A writer
    /// that stopped retrying keeps its `.retryStopped` state.
    private func lose() {
        detach()
        tracks.endSegment()
        phase = .lost
        lastTry = .now
        for arm in tracks.arms {
            tracks.gaps[arm] = tracks.gaps[arm] ?? .deviceLost
            if !retryStopped { report(.state(take: tracks.take, arm: arm, .deviceLost, status: nil)) }
        }
    }

    /// Lost to running when the device is present with the routed channels and attaches.
    private func comeBack() {
        guard phase == .lost else { return }
        lastTry = .now
        guard attach() else { return }
        appState = .recording
        for arm in tracks.arms { report(.state(take: tracks.take, arm: arm, .recording, status: nil)) }
        reportAppState()
    }

    /// A7 and A8: a process-list, default-output, or device-list event of a running app writer.
    /// The found key rebuilds the tap when it has a new process or output; else the slot takes
    /// the found set (fix check 2) and the tap goes on. No output device: lost.
    private func appChanged() {
        guard let app, let current = input?.key else { return }
        guard let found = hal.lookUpApp(app, ChannelLayout(channelCount: tracks.routedWidth) ?? .mono) else {
            return lose()
        }
        // H1: a main sub-device that no process reports can leave the device list.
        let mainGone = current.output.map { !hal.deviceExists($0) } ?? false
        guard needsRebuild(current, found.key) || mainGone else {
            // Only the processes change: the aggregate keeps its main sub-device.
            input?.key = AppKey(processes: found.key.processes, output: current.output)
            return reportAppState()
        }
        rebuild()
    }

    /// A new tap and aggregate into a new segment, with no gap: a rebuild is not a loss. A
    /// rebuild that fails makes the track lost, and the 1 s retry goes on.
    private func rebuild() {
        detach()
        tracks.endSegment()
        guard attach() else { return lose() }
        reportAppState()
    }

    /// A9: the silence warning and its rebuilds. The playing flag is a lookup of the app.
    private func checkSilence() {
        guard let app else { return }
        let layout = ChannelLayout(channelCount: tracks.routedWidth) ?? .mono
        let due = silence.due { hal.lookUpApp(app, layout)?.playing == true }
        if due.rebuild { rebuild() } else { reportAppState() }
    }

    /// Reports `.waitingForApp` when the app of the current tap has no process, `.noSound` while
    /// the silence warning shows, and `.recording` else: one report for each change.
    private func reportAppState() {
        guard app != nil, let key = input?.key else { return }
        let state: LiveTrack.State =
            key.processes.isEmpty ? .waitingForApp : silence.warns ? .noSound : .recording
        guard state != appState else { return }
        appState = state
        for arm in tracks.arms { report(.state(take: tracks.take, arm: arm, state, status: nil)) }
    }

    /// A new `DeviceInput` for the device as the lookup finds it now. The routed channels are
    /// checked before a ring exists, and a ring of an attach that threw is used again. At the
    /// keep limit it attaches no more, and it reports `.retryStopped` once.
    private func attach() -> Bool {
        guard kept < keepLimit else {
            if !retryStopped {
                retryStopped = true
                for arm in tracks.arms { report(.state(take: tracks.take, arm: arm, .retryStopped, status: nil)) }
            }
            return false
        }
        guard failedDetaches < Self.failedDetachLimit, let found = find() else { return false }
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
            let detach = try hal.attach(input)
            let teardown = found.teardown
            // Each step runs; the detach is clean only when both are (A6). The IOProc goes first:
            // an aggregate destroy with a live IOProc gives late calls (probe P12).
            self.input = (input, { [detach(), teardown()].allSatisfy { $0 } }, found.key)
        } catch .undoFailed {
            _ = found.teardown()
            keep(input, clean: false)
            return false
        } catch .undone {
            // A listener call can still be in progress, as after a clean detach.
            keep(input, clean: found.teardown())
            return false
        } catch {
            spare = ring
            if !found.teardown() { failedDetaches += 1 }
            return false
        }
        phase = .running
        lastValid = .now
        hasRecord = false
        return true
    }

    /// The device as the lookup finds it now with the routed channels. For an app, a new tap and
    /// aggregate of its processes now (decision 0030); a device has no teardown.
    private func find() -> (id: AudioObjectID, device: InputDevice, teardown: Detach, key: AppKey?)? {
        guard let app else {
            guard let found = hal.lookUp(tracks.device.uid), tracks.hasRoutedChannels(found.device) else { return nil }
            return (found.id, found.device, { true }, nil)
        }
        let layout = ChannelLayout(channelCount: tracks.routedWidth) ?? .mono
        guard let found = hal.lookUpApp(app, layout), let tap = try? hal.makeTap(found) else { return nil }
        guard tracks.hasRoutedChannels(tap.device) else {
            if !tap.teardown() { failedDetaches += 1 }
            return nil
        }
        return (tap.id, tap.device, tap.teardown, AppKey(processes: found.key.processes, output: found.output))
    }
}
