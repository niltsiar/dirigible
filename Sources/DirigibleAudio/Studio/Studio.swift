import DirigibleCore
import Foundation
import Observation

/// The facade that the app calls for one open package (decisions 0002, 0004, and 0014). It holds
/// the package lock, runs recovery at open, keeps the pending take, and saves each edit. Every
/// package write runs in one chain, so no write lands after a later one. The views observe it.
@Observable @MainActor public final class Studio {
    public enum Transport: Hashable, Sendable {
        case idle
        case recording(take: Int)
        case finalizing(take: Int)
        /// A placement (decision 0021) converts and saves this segment.
        case placing(SegmentName)
    }

    /// The package path in `packageIdentity` form. A write that finds the package moved on its
    /// volume sets it (decision 0014).
    public private(set) var url: URL
    public internal(set) var transport: Transport = .idle
    public var session: Session { history.session }
    /// Derived, not stored: `session.recording` while the transport is idle (decision 0004).
    public var pendingTake: Recording? { transport == .idle ? session.recording : nil }
    /// The last error of a finalize or of the save after it. Nil after a success.
    public private(set) var takeError: StudioError?
    /// The segments of CAFs with audio that no pool file points to (decision 0012). Derived from
    /// the session on each read, so an edit, an undo, or a redo changes it.
    public var unplacedSegments: [SegmentName] { DirigibleAudio.unplacedSegments(segmentsWithAudio, session: session) }
    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    private var history: History
    /// The disk fact under `unplacedSegments`. Open, stop, and retry read it off the main actor.
    private var segmentsWithAudio: [SegmentName]
    /// The live state of each armed track of the take or of the monitor (decision 0015), from
    /// the reports of the drain. Empty while no take records and no monitor runs.
    public internal(set) var liveTracks: [TrackID: LiveTrack] = [:]
    /// The start of the take that records. The view computes the elapsed time.
    public private(set) var recordingSince: ContinuousClock.Instant?
    /// The record time left on the disk of the take that records, at each disk check. Nil before.
    public internal(set) var recordTimeLeft: Duration?

    /// The result of the last take, set when its writers finish, before its finalize. So a
    /// finalize error keeps it. Nil from the start of the next take.
    public private(set) var lastTake: TakeResult?
    /// The pending take that the recovery of `open` finalized. Nil when the open finalized
    /// nothing, and after a new take starts. `take finalize` reads its armed tracks.
    public private(set) var recoveredTake: Recording?

    /// The Core Audio calls of a take and the player output. Tests give their own.
    @ObservationIgnored var environment = CaptureEnvironment.live {
        didSet { if environment.playerOutput != oldValue.playerOutput { outputChanged() } }
    }
    /// The playback state (decision 0016), in `Studio+Transport.swift`.
    var play: PlayState
    /// The pool files that give no frames or fewer frames. Their clips play as silence (decision
    /// 0003). Not in `play`, so the playhead poll does not update a view that reads it (0017).
    public internal(set) var missingMedia: [FileID: MediaFault]
    /// Held from the start of a take until its finalize ends.
    @ObservationIgnored private(set) var sleepAssertion: SleepAssertion?
    /// True while `startRecording` works off the main actor: every other entry point is busy.
    public internal(set) var isStarting = false
    /// The last autosave error. Nil after a good save.
    public private(set) var saveError: StudioError?
    @ObservationIgnored private var diskWatcher: Task<Void, Never>?
    /// The device writers of the take that records, by device UID.
    @ObservationIgnored private(set) var writers: [String: DeviceWriter] = [:]
    /// The armed tracks of the take that records, in arm order, with the writer of each.
    @ObservationIgnored private(set) var armed: [(id: TrackID, writer: DeviceWriter)] = []
    /// The live peaks and the head of the take (live take view), in `Studio+Live.swift`.
    @ObservationIgnored var live = LiveStore()
    /// One more for each take that begins. Two takes can have the same number.
    @ObservationIgnored private(set) var generation = 0
    /// The write chain: each package write (an autosave, a start, a finalize, or a placement) runs
    /// in its turn, so the writes run one at a time in the order of their calls.
    @ObservationIgnored private let writes = TurnQueue()
    /// True from `scheduleSave` until its write starts.
    @ObservationIgnored private var saveWaits = false
    /// The monitor order (decision 0015): each change of the monitor runs in one turn. Code that
    /// holds a monitor turn never waits for a package write, so the two orders cannot wait for
    /// each other.
    @ObservationIgnored let monitorTurns = TurnQueue()
    /// The armed tracks that the monitor meters while no take records. `monitor(armed:)` sets it.
    @ObservationIgnored var monitorRequest: [TrackID] = []
    /// The monitor writer of each device UID. Every write keeps `monitorActivity` true.
    @ObservationIgnored var monitors: [String: Monitor] = [:] {
        didSet { monitorActivity = monitors.isEmpty ? nil : monitorActivity ?? LatencyActivity(reason: monitorReason) }
    }
    /// Held while a monitor writer exists, so App Nap does not slow the drain of its 1 s ring.
    @ObservationIgnored private(set) var monitorActivity: LatencyActivity?
    /// One more for each monitor writer, so a late report of a finished one changes nothing.
    @ObservationIgnored var reportNumber = 0
    /// Held for the life of the studio. Dropping the studio releases it. Every write goes to the
    /// package that it holds.
    @ObservationIgnored let lock: PackageLock

    @ObservationIgnored let recordings: ActiveRecordings?
    /// The peak states and the pass (decision 0017), in `Studio+Peaks.swift`.
    var peakLoad: PeakLoad
    /// The running export (decision 0019), in `Studio+Export.swift`.
    var exportJob: ExportJob?
    @ObservationIgnored var exportNumber = 0
    /// The studios of the other windows (decision 0019). The app sets it; the CLI has none.
    @ObservationIgnored public var otherStudios: () -> [Studio] = { [] }
    /// The number of the export that a take of another studio ended.
    @ObservationIgnored var yieldedExport: Int?
    /// True from the start of `settle()` to its end: no peak pass and no export starts.
    private(set) var settling = false

    private init(opened: OpenedPackage, recordings: ActiveRecordings?, peakCache: URL?) {
        self.recordings = recordings
        self.peakLoad = PeakLoad(cache: peakCache)
        self.url = opened.package
        self.lock = opened.lock
        self.history = History(opened.session)
        self.takeError = opened.takeError
        self.segmentsWithAudio = opened.segmentsWithAudio
        self.recoveredTake = opened.recoveredTake
        self.play = PlayState(at: opened.session.end)
        self.missingMedia = opened.missingMedia
    }

    /// Opens the package and runs recovery (decision 0004). No file I/O runs on the main actor.
    /// Throws `.locked` when another studio or the CLI has the package. `recordings` is the list
    /// of decision 0004 that the studio keeps; the default is none. With `peakCache`, it starts
    /// a peak pass (decision 0017); with none, it computes no peaks.
    public static func open(
        _ package: URL, recordings: ActiveRecordings? = nil, peakCache: URL? = nil
    ) async throws(StudioError) -> Studio {
        let opened = try await openPackage(package, recordings: recordings)
        let studio = Studio(opened: opened, recordings: recordings, peakCache: peakCache)
        studio.loadPeaks()
        return studio
    }

    /// Runs `body` on a copy of the session and records one undo entry if it changed. A change
    /// schedules one autosave of the new session; `edit` does not wait for it.
    public func edit<Result>(_ body: (inout Session) throws(SessionError) -> Result) throws(StudioError) -> Result {
        try checkIdle()
        let before = session
        let result: Result
        do { result = try history.edit(body) } catch { throw .session(error) }
        if session != before { scheduleSave() }
        poolChanged(from: before.files)
        return result
    }

    public func undo() throws(StudioError) {
        try checkIdle()
        let before = session.files
        do { try history.undo() } catch { throw .session(error) }
        scheduleSave()
        poolChanged(from: before)
    }

    public func redo() throws(StudioError) {
        try checkIdle()
        let before = session.files
        do { try history.redo() } catch { throw .session(error) }
        scheduleSave()
        poolChanged(from: before)
    }

    /// Ends a running export (decision 0019), releases every monitor device, stops a take that
    /// records, then waits for a start, a finalize, and every write in progress. When `saveError`
    /// is set, it writes the session once more; `saveError` stays set only when that write also
    /// fails. Then it ends the peak pass (decision 0017). After it returns, no device is held, no
    /// take records, and no export, write, or pass runs.
    public func settle() async {
        // Before the first await: from now no pass, no block, and no export starts.
        settling = true
        await endExport()
        await stopPlay()
        // The monitor order does not wait for a finalize in progress.
        monitorRequest = []
        await monitorTurns.run { await applyMonitor() }
        while true {
            // A start or a finalize in progress holds an earlier ticket.
            await serialized {}
            guard case .recording = transport else { break }
            try? await stop(.requested)
        }
        if saveError != nil {
            scheduleSave()
            await serialized {}
        }
        await stopPeaks()
        settling = false
    }

    /// Runs finalize again for the pending take (decision 0004). With no pending take, it does
    /// nothing. A success records one undo entry. A failure keeps the take pending and throws.
    /// With `leavingUnreadable`, a segment that throws `.segmentUnreadable` stays unplaced and
    /// the take ends without it (decision 0021). Only a choice of the user sets it.
    public func retryFinalize(leavingUnreadable: Bool = false) async throws(StudioError) {
        try checkIdle()
        guard let take = pendingTake?.take else { return }
        transport = .finalizing(take: take)
        let error = await serialized { () async -> StudioError? in
            do throws(StudioError) {
                try await complete(take, leavingUnreadable: leavingUnreadable)
            } catch {
                return error
            }
            return nil
        }
        if let error { throw error }
    }

    /// Starts a take on the armed tracks (decision 0013). The device lookup, the microphone
    /// access read, the disk check, and the save run off the main actor; meanwhile every other
    /// entry point throws `.busy`. A throw changes nothing. A device that does not attach after
    /// the save is lost, and the take goes on. The take attaches before a running monitor
    /// releases its devices (decision 0015).
    public func startRecording(armed: [TrackID], playhead: Frames? = nil) async throws(StudioError) {
        _ = try await beginRecording(armed: armed, playhead: playhead)
    }

    /// `startRecording`, which also returns the take and the generation that it started. A stop
    /// can end that take before this call returns. With `length` (nanoseconds), each writer
    /// writes no record at or after the take start + `length`. The end is set before the
    /// hand-over waits, so no drain writes past it.
    func beginRecording(armed: [TrackID], playhead: Frames?, length: UInt64? = nil) async throws(StudioError) -> (
        take: Int, generation: Int
    ) {
        try checkIdle()
        guard pendingTake == nil else { throw .busy }
        isStarting = true
        let stopped = endPlayForTake()
        // The whole start is one step of the chain, so a stop or a settle never sees half of it.
        let result = await serialized { () async -> Result<(take: Int, generation: Int), StudioError> in
            defer { isStarting = false }
            let playhead = await takePlayhead(stopped, playhead)
            let started: StartedTake
            do throws(StudioError) {
                started = try await prepareTake(
                    of: session, lock: lock, armed: armed, playhead: playhead, environment: environment,
                    recordings: recordings, endExport: exportEnd())
            } catch {
                return .failure(error)
            }
            begin(started)
            if let length {
                let (end, overflow) = (started.session.recording?.takeStartHostTimeNanos ?? 0)
                    .addingReportingOverflow(length)
                for writer in writers.values { writer.end(atHostNanos: overflow ? .max : end) }
            }
            sleepAssertion = SleepAssertion()
            diskWatcher = watchDisk()
            // A stop from now on waits for this step and does not throw `.busy`.
            isStarting = false
            await startApps()
            await handOver()
            return .success((started.take, generation))
        }
        return try result.get()
    }

    /// Stops the take: drains and closes each device writer, starts the monitor of the request
    /// again, then finalizes and saves (decision 0004). With no take, it does nothing. A success
    /// records one undo entry. A failure keeps the take pending and throws.
    public func stopRecording() async throws(StudioError) {
        try await stop(.requested)
    }

    func stop(_ end: TakeEnd) async throws(StudioError) {
        if case .finalizing = transport { throw .busy }
        guard !isStarting else { throw .busy }
        guard case .recording(let take) = transport else { return }
        transport = .finalizing(take: take)
        stopLive()
        diskWatcher?.cancel()
        diskWatcher = nil
        // E1: the take ends now on every track, also while an app attach waits for the prompt.
        let now = hostNanosNow()
        for writer in writers.values { writer.end(atHostNanos: now) }
        let error = await serialized { () async -> StudioError? in
            let gaps = await finishWriters()
            let silent = await silentTracks()
            let dropped = armed.compactMap { track in
                track.writer.droppedFrames > 0 ? (track.id, track.writer.droppedFrames) : nil
            }
            lastTake = TakeResult(
                take: take, end: end, gaps: gaps, droppedFrames: Dictionary(uniqueKeysWithValues: dropped),
                silent: silent)
            writers = [:]
            armed = []
            liveTracks = [:]
            recordingSince = nil
            recordTimeLeft = nil
            // The come back returns its monitor turn before the finalize (decision 0015).
            await monitorTurns.run { await applyMonitor() }
            defer { sleepAssertion = nil }
            do throws(StudioError) { try await complete(take) } catch { return error }
            return nil
        }
        if let error { throw error }
    }

    /// Step 6 of the start order, on the main actor with no throw: the history entry, the
    /// results of earlier takes cleared, the writers, and the transport; then each writer
    /// attaches on its queue.
    func begin(_ started: StartedTake) {
        history.edit { $0 = started.session }
        saveError = nil  // The start save wrote the whole session.
        url = started.package
        lastTake = nil
        recoveredTake = nil
        generation += 1
        let report = Self.reporter(to: self, generation: generation)
        // A segment opens in the `Capture/` of the package that the lock holds at that time.
        let lock = lock
        let capture: @Sendable () throws(SessionFileError) -> URL = {
            try lock.package().appending(path: captureFolderName)
        }
        var devices: [InputDevice] = []
        for route in started.routes where !devices.contains(route.device) { devices.append(route.device) }
        for device in devices {
            let tracks = started.routes.filter { $0.device == device }.map {
                (arm: $0.arm, channels: $0.channels)
            }
            writers[device.uid] = DeviceWriter(
                device: device, tracks: tracks, files: TakeFiles(take: started.take, folder: capture),
                hal: environment.hal,
                report: report, silenceLimit: environment.silenceLimit,
                firstRecordLimit: environment.firstRecordLimit, ringSeconds: environment.ringSeconds,
                app: started.routes.first { $0.device == device }?.app)
        }
        // Every route's device is in `devices` above, so its writer exists.
        armed = started.routes.map { ($0.track, writers[$0.device.uid]!) }
        liveTracks = Dictionary(
            uniqueKeysWithValues: started.routes.map {
                ($0.track, LiveTrack(state: .recording, droppedFrames: 0, peak: 0))
            })
        recordingSince = .now
        beginLive(started)
        transport = .recording(take: started.take)
        for writer in writers.values where writer.app == nil { writer.start() }  // Apps: `startApps` (A5).
    }

    /// Finalize, the marker, and the save off the main actor, then the outcome here.
    private func complete(_ take: Int, leavingUnreadable: Bool = false) async throws(StudioError) {
        transport = .finalizing(take: take)
        await environment.beforeFinalize()
        let outcome = await completeTake(
            of: session, lock: lock, recordings: recordings, previous: url, leavingUnreadable: leavingUnreadable)
        takeError = outcome.error
        if outcome.error == nil { takeEnded(outcome.session) } else { dropLiveTake() }
        try apply(outcome)
    }

    /// The end of a finalize or a placement, on the main actor: the package path, the disk facts,
    /// and the transport; then the error, or one undo entry for the session that the step saved.
    func apply(_ outcome: TakeOutcome) throws(StudioError) {
        if let package = outcome.package { url = package }
        transport = .idle
        segmentsWithAudio = outcome.segmentsWithAudio
        if let missingMedia = outcome.missingMedia { self.missingMedia = missingMedia }
        if let error = outcome.error { throw error }
        let before = session.files
        history.edit { $0 = outcome.session }
        poolChanged(from: before)
    }

    /// Runs `body` after every package write that started before this call. `body` runs in the
    /// task of the caller, so no actor hop comes between its end and the caller.
    func serialized<T>(_ body: () async -> T) async -> T { await writes.run(body) }

    /// Tests only: the calls that wait for their turn of the package writes.
    var writesWaiting: Int { writes.waiters }

    /// Writes the session off the main actor, after the previous package write. It takes its
    /// ticket now, so a later start or finalize writes after it. A save that waits for its turn
    /// writes the session of that turn, so a later call adds no write: a held Nudge key makes at
    /// most one write in progress and one that waits (decision 0018).
    private func scheduleSave() {
        sendSession()
        guard !saveWaits else { return }
        saveWaits = true
        let (lock, save, ticket) = (lock, environment.saveSession, writes.ticket())
        Task {
            await writes.wait(for: ticket)
            saveWaits = false
            switch await writeSession(session, lock: lock, previous: url, recordings: recordings, save) {
            case .success(let package):
                url = package
                saveError = nil
            case .failure(let error):
                saveError = error
            }
            writes.end()
        }
    }

    /// Edits, saves, and a new take wait while a take records or finalizes (decision 0004), or while
    /// a placement runs (decision 0021).
    func checkIdle() throws(StudioError) {
        guard transport == .idle, !isStarting else { throw .busy }
    }
}
