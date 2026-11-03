import Atomics
import CoreAudio
import DirigibleCore
import Foundation

/// The recorder of one device for the whole take (decisions 0004 and 0013). A drain timer on its
/// serial queue pops the ring of the current `DeviceInput`, runs the watchdog while the device
/// runs, and tries to attach again while it is lost (`ComeBackSchedule`). `TrackSegments` writes
/// the records to the segment files of the tracks. A writer with no take files is a monitor
/// (decision 0015): it computes the peaks and writes no file. All state is confined to its serial
/// queue, so it is `@unchecked Sendable`.
final class DeviceWriter: @unchecked Sendable {
    enum Phase { case ready, running, lost, finished }
    typealias Found = (id: AudioObjectID, device: InputDevice, teardown: Detach, key: AppKey?)

    /// A writer with this many failed detaches attaches no more in the take (decision 0013).
    static let failedDetachLimit = 8

    let hal: DeviceHAL
    /// The journal of the front end (decision 0059): the attach and tap lines.
    let log: DiagnosticLog
    /// The bundle ID of an app source (decision 0030), else nil. An app writer makes a tap and
    /// its aggregate at each attach, and the detach tears both down.
    let app: String?
    let report: @Sendable (Report) -> Void
    private let drainInterval: Duration
    private let silenceLimit: Duration
    private let firstRecordLimit: Duration
    let ringSeconds: Double
    /// At this many kept inputs, the writer attaches no more (decision 0015).
    let keepLimit: Int
    private let queue: DispatchQueue
    var tracks: TrackSegments
    var phase = Phase.ready
    /// The attached appearance of the device, its detach, and for an app the key of the
    /// appearance: its processes and the main sub-device of its aggregate (decision 0030).
    var input: (input: DeviceInput, detach: Detach, key: AppKey?)?
    /// The detaches that failed: a late IOProc call can still use their ring bytes.
    var failedDetaches = 0
    /// The inputs that `keep` kept for the process life.
    var kept = 0
    /// True after the writer reported `.retryStopped`.
    var retryStopped = false
    /// The last `runningState` that an app writer reported: `.waitingForApp`, `.noAccess`,
    /// `.noSound`, or `.recording`.
    var appState = LiveTrack.State.recording
    /// True after a grant check of a monitor app tap gave `'!hog'`, until a noErr check or a
    /// sample that is not zero (decision 0006).
    var noAccess = false
    /// The silence check of an app track (A9): the monitor rule for a writer with no take.
    var silence: SilenceCheck
    /// The rebuilds of `retapSilent()`.
    var silentRetaps = 0
    /// The ring of an attach that threw before its IOProc existed: no call can reach it.
    var spare: CaptureRing?
    private var unwatch: Detach?
    private var timer: DispatchSourceTimer?
    /// The watchdog clock: the last valid record, or the attach.
    var lastValid = ContinuousClock.now
    /// True after the first valid record of the current appearance. Before it, the watchdog
    /// uses `firstRecordLimit`.
    var hasRecord = false
    /// When a lost writer tries to attach again.
    var comeBacks = ComeBackSchedule(at: .now)
    /// The device-list posts since the last handler took them. Only the post from 0 queues a
    /// handler, so one handler serves each post before it runs.
    private let listPosts = ManagedAtomic<Int>(0)
    private let dropped = ManagedAtomic<Int>(0)
    /// The limit of the `device dropped` lines.
    var drops = LineLimit()
    /// `tracks.wavBytes` after each drain.
    private let wavByteCount = ManagedAtomic<Int64>(0)
    /// The take start host time H_T of a pre-roll take (decision 0070, **Late start**): the limit is
    /// this base + 3 IO buffers of the device. Nil for a Command-R take and a monitor.
    private let lateStartBase: UInt64?
    /// The first record of the take was compared with `lateStartBase`.
    private var startChecked = false
    private let late = ManagedAtomic<Bool>(false)
    /// The start state and the stop time, which the Studio sets from any thread.
    let lifecycle = WriterLifecycle()
    /// The name of the device or the app, for an error text. Any thread reads it.
    let name: String

    /// `tracks` holds the arm index and the 1-based device channels of each track. The start
    /// checks of `Studio` make every channel exist on the device. `files` is nil for a monitor,
    /// which reports take 0 (`tracks.take`). `drainInterval`, `silenceLimit`, `firstRecordLimit`,
    /// and `ringSeconds` are parameters so that tests stay fast. `app` is the bundle ID of an app
    /// source; then `device` has the UID `app:<bundle ID>` and the app name.
    init(
        device: InputDevice, tracks: [(arm: Int, channels: Route.Channels)], files: TakeFiles?, hal: DeviceHAL,
        log: DiagnosticLog = .disabled, report: @escaping @Sendable (Report) -> Void = { _ in },
        drainInterval: Duration = .milliseconds(50),
        silenceLimit: Duration = .seconds(2), firstRecordLimit: Duration = .seconds(10), ringSeconds: Double = 10,
        keepLimit: Int = .max, app: String? = nil, lateStartBase: UInt64? = nil
    ) {
        self.hal = hal
        self.log = log
        self.app = app
        self.report = report
        self.drainInterval = drainInterval
        self.silenceLimit = silenceLimit
        self.firstRecordLimit = firstRecordLimit
        self.ringSeconds = ringSeconds
        self.keepLimit = keepLimit
        self.lateStartBase = lateStartBase
        silence = SilenceCheck(files == nil ? .monitor : .take)
        name = device.name
        queue = DispatchQueue(label: "Dirigible.DeviceWriter.\(tracks.map(\.arm).min() ?? 0)")
        self.tracks = TrackSegments(
            device: device, tracks: tracks, files: files, report: report, routesLastChannels: app != nil, log: log)
    }

    deinit { timer?.cancel() }

    /// The frames of the take that the ring or the writer dropped: a full ring, a record without
    /// valid times, and a record with no routed channel or a wrong size. Any thread can read it.
    var droppedFrames: Int { dropped.load(ordering: .relaxed) }
    /// The first frame of the take, less the input latency, came after `lateStartBase` + 3 IO
    /// buffers of the device. Any thread can read it.
    var startedLate: Bool { late.load(ordering: .relaxed) }

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
            if !attach() { lose(.attachFailed) }
        }
    }

    /// Returns after the first attach try of `start()`: a barrier on the queue.
    func started() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    }

    /// A device listener passes its own `DeviceInput`; the device-list listener passes nil. A
    /// rate, layout, or IsAlive event from an input that is not the current one does nothing. A
    /// device-list handler reads the devices when it runs, so one queued handler serves each
    /// device-list post before it runs.
    func post(_ event: Event, from sender: DeviceInput?) {
        if case .devicesChanged = event, listPosts.loadThenWrappingIncrement(ordering: .acquiringAndReleasing) > 0 {
            return
        }
        queue.async { [self] in handle(event, from: sender) }
    }

    /// Sends `retapSilent()` to the queue.
    func retapIfSilent() { queue.async { [self] in retapSilent() } }

    /// Detaches, writes the rest of the ring, closes every segment, and ends the timer. Returns
    /// the gaps of the take. A second call returns the same gaps.
    @discardableResult
    func finish() async -> [Int: TakeResult.Gap] {
        await withCheckedContinuation { (done: CheckedContinuation<[Int: TakeResult.Gap], Never>) in
            queue.async { [self] in
                finishSteps()
                done.resume(returning: tracks.gaps)
            }
        }
    }

    /// The steps of `finish` with no wait: the queue runs them after a blocked attach returns.
    func finishLater() { queue.async { [self] in finishSteps() } }

    /// The stop gives up a writer that never attached (decision 0030): a late attach tears down
    /// and writes nothing. False when an attach came first.
    func abandon() -> Bool { lifecycle.abandon() }

    /// The start state: not attached, attached, or abandoned. Any thread reads it.
    var startState: WriterLifecycle.Start { lifecycle.state }

    private func finishSteps() {
        guard phase != .finished else { return }
        detach()
        noteLimitedLines(at: .now, force: true)
        tracks.endSegment()
        _ = unwatch?()
        spare?.deallocate()
        spare = nil
        timer?.cancel()
        phase = .finished
    }

    /// The writer writes no record that starts at or after `end` (host time), so a take does not
    /// grow while the stop waits for the queue. Any thread calls it, with no queue hop. Such a
    /// record still restarts the watchdog clock.
    func end(atHostNanos end: UInt64) { lifecycle.end(atHostNanos: end) }

    /// The app name when the silence warning showed and no sound came in the take (A9), else nil.
    func silentApp() async -> String? {
        await withCheckedContinuation { done in
            queue.async { [self] in done.resume(returning: silence.warns ? tracks.device.name : nil) }
        }
    }

    /// The WAV bytes of the take so far, for the disk rule. Any thread reads it with no queue hop,
    /// so a writer that waits (an app attach at the prompt, E1) never holds the disk watch.
    var wavBytes: Int64 { wavByteCount.load(ordering: .relaxed) }

    private func handle(_ event: Event, from sender: DeviceInput?) {
        var posts = 0
        if case .devicesChanged = event { posts = listPosts.exchange(0, ordering: .acquiringAndReleasing) }
        guard phase == .running || phase == .lost else { return }
        if case .devicesChanged = event {
            note(event, posts: posts)
            if phase == .running, app != nil { return appChanged() }
            if phase == .running, hal.lookUp(tracks.device.uid)?.id != input?.input.id { lose(.list) }
            guard phase == .lost, comeBacks.event(at: .now) else { return }
            return comeBack()
        }
        guard let current = input?.input, current === sender else { return }
        note(event, posts: 0)
        switch event {
        case .layout(let channels):
            // A record in the ring of the other layout ends the segment again and re-routes.
            tracks.endSegment()
            guard tracks.use(channels: channels) else { return lose(.layout) }
            growRing(rate: tracks.device.nominalRate, channels: tracks.device.channelCount)
        case .rate(let rate):
            // The rate is in the ring already: the next record header breaks the segment.
            growRing(rate: rate, channels: tracks.device.channelCount)
        case .alive(false):
            // A8: an app aggregate rebuilds on the new output; a device is lost.
            if app != nil { rebuild(cause: "alive") } else { lose(.alive) }
        case .alive(true), .devicesChanged:
            break
        }
    }

    /// A rate or a layout that needs a larger ring starts a new appearance, so the IO thread never
    /// writes into a ring that is too small or touches a new page. A failed attach loses the device.
    private func growRing(rate: Double, channels: Int) {
        guard let current = input?.input,
            CaptureRing.capacity(rate: rate, channels: channels, seconds: ringSeconds) > current.ring.capacity
        else { return }
        detach()
        if !attach() { lose(.attachFailed) }
    }

    private func tick() {
        drain()
        if app != nil, phase == .running { checkSilence() }
        let now = ContinuousClock.now
        noteLimitedLines(at: now)
        if phase == .running, now - lastValid >= (hasRecord ? silenceLimit : firstRecordLimit) {
            lose(.noRecord)
        } else if phase == .lost, comeBacks.tick(at: now) {
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
            if !startChecked { checkStart(record) }
            if record.hostTimeNanos < lifecycle.endHostNanos, !tracks.write(record) { lost += record.frameCount }
            lastValid = .now
            hasRecord = true
            hosts = (hosts?.first ?? record.hostTimeNanos, record.hostTimeNanos)
        }
        dropped.wrappingIncrement(by: lost, ordering: .relaxed)
        if lost > 0 { drops.add(Int64(lost), at: .now) }
        wavByteCount.store(tracks.wavBytes, ordering: .relaxed)
        let levels = tracks.takeLevels()
        let heard = levels.values.contains { $0.peak > 0 }
        if heard { noAccess = false }
        if app != nil, let hosts {
            silence.take(
                firstHost: hosts.first, lastHost: hosts.last, heard: heard,
                hasProcess: input?.key?.processes.isEmpty == false)
        }
        report(
            .levels(take: tracks.take, arms: levels, latencyNanos: tracks.latencyNanos, droppedFrames: droppedFrames))
    }

    /// Compares the first record of the take with the limit, `lateStartBase` + 3 IO buffers; the IO
    /// buffer is the record length.
    private func checkStart(_ record: InputRecord) {
        startChecked = true
        guard let lateStartBase else { return }
        let buffers = Int64((Double(3 * record.frameCount) * 1e9 / record.nominalRate).rounded())
        let first = Int64(bitPattern: record.hostTimeNanos) - tracks.latencyNanos
        if first > Int64(bitPattern: lateStartBase) + buffers { late.store(true, ordering: .relaxed) }
    }

    /// Detaches the current input and writes the rest of its ring, then keeps the input.
    func detach() {
        guard let (current, detach, _) = input else { return }
        let clean = detach()
        drain()
        keep(current, clean: clean)
        input = nil
    }

    /// Keeps `input` and its ring atomics for the process life (decision 0013): a listener call
    /// that was in progress during its removal can use them at any later time, also after the
    /// take. A clean detach frees the ring bytes, because no IOProc call can come.
    func keep(_ input: DeviceInput, clean: Bool) {
        _ = Unmanaged.passRetained(input)
        kept += 1
        if clean { input.ring.deallocateBytes() } else { countFailedDetach() }
    }

    /// Running or ready to lost: detach, end the segments, report, and record the gaps. A writer
    /// that stopped retrying keeps its `.retryStopped` state.
    func lose(_ cause: LossCause) {
        log.note(.device, "lost", level: .error, ["device": .text(name), "cause": .text(cause.rawValue)])
        detach()
        tracks.endSegment()
        phase = .lost
        comeBacks.lost(at: .now)
        for arm in tracks.arms {
            tracks.gaps[arm] = tracks.gaps[arm] ?? .deviceLost
            if !retryStopped { report(.state(take: tracks.take, arm: arm, .deviceLost, status: nil)) }
        }
    }

    /// Lost to running when the device is present with the routed channels and attaches.
    private func comeBack() {
        guard phase == .lost else { return }
        let attached = attach()
        noteComeBack(attached: attached)
        guard attached else { return }
        appState = .recording
        for arm in tracks.arms { report(.state(take: tracks.take, arm: arm, .recording, status: nil)) }
        reportAppState()
    }
}
