import DirigibleCore
import Foundation
import Observation

/// The facade that the app calls for one open package (decisions 0002, 0004, and 0014). It holds
/// the package lock, runs recovery at open, keeps the pending take, and saves each edit. Every
/// package write runs in one chain, so no write lands after a later one. The views observe it.
@Observable @MainActor public final class Studio {
    /// The package path in `packageIdentity` form. A write that finds the package moved on its
    /// volume sets it (decision 0014).
    public internal(set) var url: URL
    public internal(set) var transport: Transport = .idle
    public var session: Session { history.session }
    /// One more for each recorded edit, undo, and redo of the session.
    public var sessionRevision: Int { history.revision }
    /// Derived, not stored: `session.recording` while the transport is idle (decision 0004).
    public var pendingTake: Recording? { transport == .idle ? session.recording : nil }
    /// The last error of a finalize or of the save after it. Nil after a success.
    public internal(set) var takeError: StudioError?
    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }
    /// The agent of the change that Undo reverts, or nil for a user change (decision 0046).
    public var undoAgent: AgentName? { history.undoAgent }
    /// The agent of the change that Redo makes again, or nil for a user change.
    public var redoAgent: AgentName? { history.redoAgent }
    /// The backups of the package, newest first (decision 0043). The open and each write turn set it.
    public internal(set) var backups: [Backup]
    /// The take anchors, and the take map and its change of the last revision (decision 0061).
    var takeSyncState: TakeSyncState

    private(set) var history: History
    /// The disk fact under `unplacedSegments`. Open, stop, and retry read it off the main actor.
    var segmentsWithAudio: [SegmentName]
    private(set) var notAudioSegments: Set<SegmentName>
    /// The live state of each armed track of the take or of the monitor (decision 0015), from
    /// the reports of the drain. Empty while no take records and no monitor runs.
    public internal(set) var liveTracks: [TrackID: LiveTrack] = [:] {
        didSet {
            liveTrackWrites += 1
            let states = liveTracks.mapValues(\.state)
            if states != liveStates { liveStates = states }
        }
    }
    /// The state of each entry of `liveTracks`, changed only at a state change. The track rows
    /// read it, so a meter report runs no row body (decision 0014).
    public private(set) var liveStates: [TrackID: LiveTrack.State] = [:]
    /// The writes of `liveTracks`, for the tests: one for each meter report.
    @ObservationIgnored var liveTrackWrites = 0
    /// The start of the take that records. The view computes the elapsed time.
    public internal(set) var recordingSince: ContinuousClock.Instant?
    /// The record time left on the disk of the take that records: from the take start, then at
    /// each disk check. Nil with no take.
    public internal(set) var recordTimeLeft: Duration?

    /// The result of the last take, set when its writers finish, before its finalize. So a
    /// finalize error keeps it. Nil from the start of the next take.
    public internal(set) var lastTake: TakeResult?
    /// The pending take that the recovery of `open` finalized. Nil when the open finalized
    /// nothing, and after a new take starts. `take finalize` reads its armed tracks.
    public private(set) var recoveredTake: Recording?

    /// The Core Audio calls of a take and the player output. Tests give their own.
    @ObservationIgnored var environment = CaptureEnvironment.live {
        didSet {
            if environment.playerOutput != oldValue.playerOutput { outputChanged() }
            speedUnitFound = nil
        }
    }
    /// The journal that `open` got from the front end (decision 0059), for the lines of the window.
    public var log: DiagnosticLog { environment.log }
    /// The speed lookup of `environment` found the unit: one lookup, not one at each chrome read.
    @ObservationIgnored var speedUnitFound: Bool?
    /// The effect preview of decision 0054, in `Studio+Preview.swift`.
    var effectPreview = EffectPreviewSlot()
    /// The playback state (decision 0016), in `Studio+Transport.swift`.
    var play: PlayState
    /// The loudness of the heard frame (decision 0033). Only the display tick reads it, so no
    /// view observes it. It has M and S only while a 1x forward play runs: each stop holds I and TP.
    @ObservationIgnored public internal(set) var loudness = LoudnessValues.none
    /// The pool files that give no frames or fewer frames. Their clips play as silence (decision
    /// 0003). Not in `play`, so the playhead poll does not update a view that reads it (0017).
    public internal(set) var missingMedia: [FileID: MediaFault]
    /// Held from the start of a take until its finalize ends.
    @ObservationIgnored var sleepAssertion: SleepAssertion?
    /// True while `startRecording` works off the main actor: every other entry point is busy.
    public internal(set) var isStarting = false
    /// The last autosave error. Nil after a good save, finalize, or placement write.
    public internal(set) var saveError: StudioError?
    @ObservationIgnored var diskWatcher: Task<Void, Never>?
    /// The stop of a timed take (decision 0048). Each stop cancels it.
    @ObservationIgnored var takeTimer: Task<Void, Never>?
    /// The device writers of the take that records, by device UID.
    @ObservationIgnored var writers: [String: DeviceWriter] = [:]
    /// The armed tracks of the take that records, in arm order, with the writer of each.
    @ObservationIgnored var armed: [(id: TrackID, writer: DeviceWriter)] = []
    /// The waits of the take start in progress, which a stop ends (decision 0030).
    @ObservationIgnored var startCut: WaitCut?
    /// The writers of the pending take that did not finish by the stop deadline. Retry Finalize
    /// waits for them again. Each one still holds the package lock (decision 0012).
    @ObservationIgnored var unfinishedWriters: [UnfinishedWriter] = []
    /// The live peaks and the head of the take (live take view), in `Studio+Live.swift`.
    @ObservationIgnored var live = LiveStore()
    /// One more for each take that begins. Two takes can have the same number.
    @ObservationIgnored private(set) var generation = 0
    /// The write chain: each package write (an autosave, a start, a finalize, or a placement) runs
    /// in its turn, so the writes run one at a time in the order of their calls.
    @ObservationIgnored private let writes = TurnQueue()
    /// True from `scheduleSave` until its write starts.
    @ObservationIgnored private(set) var saveWaits = false
    /// The revision of the session that the last write saved (decision 0071).
    @ObservationIgnored var savedRevision = 0
    /// The raw sweep job (decision 0071), in `Studio+RawSweep.swift`.
    @ObservationIgnored var rawSweepJob = RawSweepJob()
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
    /// The tracks whose device input plays in the default output (decision 0044).
    var listenRequest: [TrackID] = []
    /// The Listener of each listened device UID, and the number of its reports.
    @ObservationIgnored var listeners: [String: (listener: Listener, number: Int)] = [:]
    /// One more for each Listener, so a late report of a released one changes nothing.
    @ObservationIgnored var listenNumber = 0
    /// The listen order (decision 0044): each change of the Listeners runs in one turn. It is not
    /// the monitor order, where a turn can wait for a monitor writer until the stop limit or the
    /// start deadline.
    @ObservationIgnored let listenTurns = TurnQueue()
    /// The last report of the current Listener of each device UID, when it is not `.playing`.
    var deviceReports: [String: ListenReport] = [:]
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
    /// The running agent reads by time (decision 0062), in `Studio+Read.swift`.
    @ObservationIgnored var readRuns: [ReadRun] = []
    /// The waits of `readsEnded()`, resumed when the last read ends.
    @ObservationIgnored var readWaiters: [CheckedContinuation<Void, Never>] = []
    /// The running transcription job (decision 0065), in `Studio+Transcribe.swift`.
    @ObservationIgnored var transcribing: TranscribeRun?
    /// The number of the export that a take of another studio ended.
    @ObservationIgnored var yieldedExport: Int?
    /// Why the last export stopped before its end, read after its `.export(.cancelled)`. Nil
    /// while it runs.
    @ObservationIgnored public internal(set) var exportStop: ExportStop?
    /// Why the last import stopped before its end, read after its `.audioImport(.cancelled)`. Nil
    /// until a stop, and after a cancel of the calling task.
    @ObservationIgnored public internal(set) var importStop: ExportStop?
    /// The cancel flag of the running level or duck, or nil: each `runReadJob` makes a clear one
    /// (decisions 0049 and 0060).
    @ObservationIgnored var readJobFlags: ImportFlags?
    /// The largest fraction of the running file import, 0 at the start of each run. The banner of
    /// an agent import shows it (decision 0049).
    public internal(set) var importProgress = 0.0
    /// True from the start of `settle()` to its end: no peak pass and no export starts.
    private(set) var settling = false

    private init(opened: OpenedPackage, recordings: ActiveRecordings?, peakCache: URL?, log: DiagnosticLog) {
        self.recordings = recordings
        self.peakLoad = PeakLoad(cache: peakCache)
        self.url = opened.package
        self.lock = opened.lock
        self.history = History(opened.session)
        self.takeError = opened.takeError
        self.segmentsWithAudio = opened.segmentsWithAudio
        self.notAudioSegments = opened.notAudioSegments
        self.recoveredTake = opened.recoveredTake
        self.play = PlayState(at: opened.session.end)
        self.missingMedia = opened.missingMedia
        self.backups = opened.backups
        self.takeSyncState = TakeSyncState(opened.session, anchors: opened.takeAnchors)
        environment.log = log
    }

    /// Opens the package and runs recovery (decision 0004). No file I/O runs on the main actor.
    /// Throws `.locked` when another studio or the CLI has the package. `recordings` is the list
    /// of decision 0004 that the studio keeps; the default is none. With `peakCache`, it starts
    /// a peak pass (decision 0017); with none, it computes no peaks. It starts the raw sweep job
    /// (decision 0071) and does not wait for it. The studio writes its lines to `log`, the journal
    /// of the front end (decision 0059).
    public static func open(
        _ package: URL, recordings: ActiveRecordings? = nil, peakCache: URL? = nil, log: DiagnosticLog = .disabled
    ) async throws(StudioError) -> Studio {
        let opened = try await openPackage(package, recordings: recordings, log: log)
        let studio = Studio(opened: opened, recordings: recordings, peakCache: peakCache, log: log)
        studio.loadPeaks()
        studio.sweepRaw()
        return studio
    }

    /// Runs `body` as a part of the last recorded edit (`History.amend`), with the autosave of
    /// `edit`.
    public func amend(_ body: (inout Session) throws(SessionError) -> Void) throws(StudioError) {
        try checkIdle()
        let before = session
        do { try history.amend(body) } catch { throw .session(error) }
        if session != before { scheduleSave() }
        poolChanged(from: before.files)
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
        let (before, agent) = (session.files, redoAgent)
        do { try history.redo() } catch { throw .session(error) }
        scheduleSave()
        poolChanged(from: before, agent: agent)
    }

    /// Ends a running import, export, and agent read (decisions 0040, 0019, and 0062), turns off every Listener,
    /// releases every monitor device, stops a take that records, then waits for a start, a finalize, an import,
    /// a read of a package file, and every write in progress. With `saveError`, it writes the session once more; `saveError` stays
    /// only when that write fails too. Then it ends the peak pass (decision 0017) and the raw sweep job (0071). After
    /// it returns, no device is held, no take records, and no export, read, write, pass, or sweep runs.
    public func settle() async {
        // Before the first await: from now no pass, no block, and no export starts.
        settling = true
        endImport(.close)
        endReads(.close)
        await endListen()
        await endExport(.close)
        await readsEnded()
        await stopPlay()
        await endEffectPreview()
        // The monitor order does not wait for a finalize in progress.
        monitorRequest = []
        await monitorTurns.run { await applyMonitor() }
        while true {
            // A start or a finalize in progress holds an earlier ticket.
            await startsQueued()
            await serialized {}
            guard case .recording = transport else { break }
            try? await stop(.requested)
        }
        if saveError != nil {
            scheduleSave()
            await serialized {}
        }
        // After the last write: the state that the user hands to the CLI or an agent (0043).
        await serialized { if let list = await keepBackupAtClose(lock) { backups = list } }
        await stopPeaks()
        await stopRawSweeps([self])
        settling = false
    }

    /// Step 6 of the start order, on the main actor with no throw: the history entry, the
    /// results of earlier takes cleared, the writers, and the transport; then each writer
    /// attaches on its queue.
    func begin(_ started: StartedTake) {
        logTake(started)
        let span = environment.log.begin(.take, "writers-begin")
        defer { span.end("writers") }
        history.edit { $0 = started.session }
        (saveError, savedRevision) = (nil, sessionRevision)  // The start save wrote the whole session.
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
                hal: environment.hal, log: environment.log,
                report: report, silenceLimit: environment.silenceLimit,
                firstRecordLimit: environment.firstRecordLimit, ringSeconds: environment.ringSeconds,
                app: started.routes.first { $0.device == device }?.app, lateStartBase: started.lateStartBase)
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

    /// The end of a finalize or a placement, on the main actor: the package path, the disk facts,
    /// and the transport; then the error, or the undo entries of the take and of its level (0031).
    func apply(_ outcome: TakeOutcome) throws(StudioError) {
        if let package = outcome.package { url = package }
        transport = .idle
        segmentsWithAudio = outcome.segmentsWithAudio
        notAudioSegments = outcome.notAudioSegments
        if let missingMedia = outcome.missingMedia { self.missingMedia = missingMedia }
        if let backups = outcome.backups { self.backups = backups }
        if let anchors = outcome.takeAnchors { takeSyncState.store(anchors, session: session) }
        if let error = outcome.error { throw error }
        saveError = nil
        let before = session.files
        if let beforeLevel = outcome.beforeLevel { history.edit { $0 = beforeLevel } }
        history.edit { $0 = outcome.session }
        savedRevision = sessionRevision
        poolChanged(from: before, transitions: false)
    }

    /// The pool change of Remove Unused Files (decision 0047): the session and each undo and redo
    /// entry lose the pool entries that name a file of `files`, with no new entry. `saved` is the
    /// session before the prune and the session that the prune saved.
    func removePoolEntries(_ files: UnusedFiles, saved: (before: Session, pruned: Session)) throws(SessionError) {
        try history.removeUnusedFiles(files.poolIDs, saved: saved)
    }

    /// The one undo entry of `runReadJob` (a level or a duck) or of a file import, after its write.
    /// The write saved the whole session.
    func recordLevel(_ leveled: Session, agent: AgentName? = nil) {
        history.edit(agent: agent) { $0 = leveled }
        (saveError, savedRevision) = (nil, sessionRevision)
    }

    /// Runs `body` after every package write that started before this call. `body` runs in the
    /// task of the caller, so no actor hop comes between its end and the caller.
    func serialized<T>(_ body: () async -> T) async -> T { await writes.run(body) }

    /// Tests only: the calls that wait for their turn of the package writes.
    var writesWaiting: Int { writes.waiters }

    /// The steps of `edit` after its busy check: one undo entry and one autosave when `body`
    /// changes the session, then the pool check. The take marker calls it during a take.
    func recordEdit<Result, Failure: Error>(
        agent: AgentName?, _ body: (inout Session) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        let (before, revision) = (session, sessionRevision)
        let result = try history.edit(agent: agent, body)
        if session != before { scheduleSave() }
        // A no-op edit keeps the revision, which a level or a duck can have moved with no change.
        if sessionRevision != revision { poolChanged(from: before.files, agent: agent) }
        return result
    }

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
            let revision = sessionRevision
            switch await writeSession(session, lock: lock, previous: url, recordings: recordings, save) {
            case .success(let written):
                url = written.package
                backups = written.backups
                (saveError, savedRevision) = (nil, revision)
            case .failure(let error):
                saveError = error
            }
            writes.end()
        }
    }
}
