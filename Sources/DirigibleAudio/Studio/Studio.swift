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
    }

    /// The package path in `packageIdentity` form. A write that finds the package moved on its
    /// volume sets it (decision 0014).
    public private(set) var url: URL
    public private(set) var transport: Transport = .idle
    public var session: Session { history.session }
    /// Derived, not stored: `session.recording` while the transport is idle (decision 0004).
    public var pendingTake: Recording? { transport == .idle ? session.recording : nil }
    /// The last error of a finalize or of the save after it. Nil after a success.
    public private(set) var takeError: StudioError?
    /// The stems of CAFs with audio that no pool file points to (decision 0012). Derived from
    /// the session on each read, so an edit, an undo, or a redo changes it.
    public var unplacedSegments: [String] { DirigibleAudio.unplacedSegments(segmentsWithAudio, session: session) }
    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    private var history: History
    /// The disk fact under `unplacedSegments`. Open, stop, and retry read it off the main actor.
    private var segmentsWithAudio: [SegmentName]
    /// The live state of each armed track of the take, from the reports of the drain. Empty while
    /// no take records.
    public private(set) var liveTracks: [TrackID: LiveTrack] = [:]
    /// The start of the take that records. The view computes the elapsed time.
    public private(set) var recordingSince: ContinuousClock.Instant?

    /// The result of the last take, set when its writers finish, before its finalize. So a
    /// finalize error keeps it. Nil from the start of the next take.
    public private(set) var lastTake: TakeResult?
    /// The pending take that the recovery of `open` finalized. Nil when the open finalized
    /// nothing, and after a new take starts. `take finalize` reads its armed tracks.
    public private(set) var recoveredTake: Recording?

    /// The Core Audio calls of a take. Tests give their own.
    @ObservationIgnored var environment = CaptureEnvironment.live
    /// Held from the start of a take until its finalize ends.
    @ObservationIgnored private(set) var sleepAssertion: SleepAssertion?
    /// True while `startRecording` works off the main actor: every other entry point is busy.
    public private(set) var isStarting = false
    /// The last autosave error. Nil after a good save.
    public private(set) var saveError: StudioError?
    @ObservationIgnored private var diskWatcher: Task<Void, Never>?
    /// The device writers of the take that records, by device UID.
    @ObservationIgnored private(set) var writers: [String: DeviceWriter] = [:]
    /// The armed tracks of the take that records, in arm order, with the writer of each.
    @ObservationIgnored private var armed: [(id: TrackID, writer: DeviceWriter)] = []
    /// One more for each take that begins. Two takes can have the same number.
    @ObservationIgnored private(set) var generation = 0
    /// The write chain: each package write (an autosave, a start, or a finalize) takes the next
    /// ticket and runs when `serving` reaches it, so the writes run one at a time in ticket order.
    @ObservationIgnored private var tickets = 0
    @ObservationIgnored private var serving = 0
    @ObservationIgnored private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    /// Held for the life of the studio. Dropping the studio releases it. Every write goes to the
    /// package that it holds.
    @ObservationIgnored let lock: PackageLock

    private init(opened: OpenedPackage) {
        self.url = opened.package
        self.lock = opened.lock
        self.history = History(opened.session)
        self.takeError = opened.takeError
        self.segmentsWithAudio = opened.segmentsWithAudio
        self.recoveredTake = opened.recoveredTake
    }

    /// Opens the package and runs recovery (decision 0004). No file I/O runs on the main actor.
    /// Throws `.locked` when another studio or the CLI has the package.
    public static func open(_ package: URL) async throws(StudioError) -> Studio {
        Studio(opened: try await openPackage(package))
    }

    /// Runs `body` on a copy of the session and records one undo entry if it changed. A change
    /// schedules one autosave of the new session; `edit` does not wait for it.
    public func edit<Result>(_ body: (inout Session) throws(SessionError) -> Result) throws(StudioError) -> Result {
        try checkIdle()
        let before = session
        let result: Result
        do { result = try history.edit(body) } catch { throw .session(error) }
        if session != before { scheduleSave() }
        return result
    }

    public func undo() throws(StudioError) {
        try checkIdle()
        do { try history.undo() } catch { throw .session(error) }
        scheduleSave()
    }

    public func redo() throws(StudioError) {
        try checkIdle()
        do { try history.redo() } catch { throw .session(error) }
        scheduleSave()
    }

    /// Stops a take that records, then waits for a start, a finalize, and every write in
    /// progress. When `saveError` is set, it writes the session once more; `saveError` stays set
    /// only when that write also fails. After it returns, no take records and no write runs.
    public func settle() async {
        while true {
            // A start or a finalize in progress holds an earlier ticket.
            await serialized {}
            guard case .recording = transport else { break }
            try? await stop(.requested)
        }
        guard saveError != nil else { return }
        scheduleSave()
        await serialized {}
    }

    /// Runs finalize again for the pending take (decision 0004). With no pending take, it does
    /// nothing. A success records one undo entry. A failure keeps the take pending and throws.
    public func retryFinalize() async throws(StudioError) {
        try checkIdle()
        guard let take = pendingTake?.take else { return }
        transport = .finalizing(take: take)
        let error = await serialized { () async -> StudioError? in
            do throws(StudioError) { try await complete(take) } catch { return error }
            return nil
        }
        if let error { throw error }
    }

    /// Starts a take on the armed tracks (decision 0013). The device lookup, the microphone
    /// access read, the disk check, and the save run off the main actor; meanwhile every other
    /// entry point throws `.busy`. A throw changes nothing. A device that does not attach after
    /// the save is lost, and the take goes on.
    public func startRecording(armed: [TrackID], playhead: Frames) async throws(StudioError) {
        _ = try await beginRecording(armed: armed, playhead: playhead)
    }

    /// `startRecording`, which also returns the take and the generation that it started. A stop
    /// can end that take before this call returns.
    func beginRecording(armed: [TrackID], playhead: Frames) async throws(StudioError) -> (take: Int, generation: Int) {
        try checkIdle()
        guard pendingTake == nil else { throw .busy }
        isStarting = true
        // The whole start is one step of the chain, so a stop or a settle never sees half of it.
        let result = await serialized { () async -> Result<(take: Int, generation: Int), StudioError> in
            defer { isStarting = false }
            let started: StartedTake
            do throws(StudioError) {
                started = try await prepareTake(
                    of: session, lock: lock, armed: armed, playhead: playhead, environment: environment)
            } catch {
                return .failure(error)
            }
            begin(started)
            sleepAssertion = SleepAssertion()
            diskWatcher = watchDisk()
            return .success((started.take, generation))
        }
        return try result.get()
    }

    /// Stops the take: drains and closes each device writer, then finalizes and saves
    /// (decision 0004). With no take, it does nothing. A success records one undo entry. A
    /// failure keeps the take pending and throws.
    public func stopRecording() async throws(StudioError) {
        try await stop(.requested)
    }

    private func stop(_ end: TakeEnd) async throws(StudioError) {
        if case .finalizing = transport { throw .busy }
        guard !isStarting else { throw .busy }
        guard case .recording(let take) = transport else { return }
        transport = .finalizing(take: take)
        diskWatcher?.cancel()
        diskWatcher = nil
        let error = await serialized { () async -> StudioError? in
            var gaps: [TrackID: TakeResult.Gap] = [:]
            for writer in writers.values {
                for (arm, state) in await writer.finish() { gaps[armed[arm - 1].id] = state }
            }
            let dropped = armed.compactMap { track in
                track.writer.droppedFrames > 0 ? (track.id, track.writer.droppedFrames) : nil
            }
            lastTake = TakeResult(
                take: take, end: end, gaps: gaps, droppedFrames: Dictionary(uniqueKeysWithValues: dropped))
            writers = [:]
            armed = []
            liveTracks = [:]
            recordingSince = nil
            defer { sleepAssertion = nil }
            do throws(StudioError) { try await complete(take) } catch { return error }
            return nil
        }
        if let error { throw error }
    }

    /// Each check interval: stops the take when the free space is less than the WAV bytes of
    /// the take plus 1 GB. The reads run off the main actor.
    private func watchDisk() -> Task<Void, Never> {
        let (lock, environment, writers) = (lock, environment, Array(writers.values))
        return Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: environment.diskCheckInterval)
                var wav: Int64 = 0
                for writer in writers { wav += await writer.wavBytes() }
                guard await freeBytes(of: lock, environment) < wav + diskMargin, !Task.isCancelled else { continue }
                try? await self?.stop(.diskLow)
                return
            }
        }
    }

    /// The device writer of `uid` in the take that records. For tests.
    func writer(_ uid: String) -> DeviceWriter? { writers[uid] }

    /// The test seam of decision 0004: starts a take from device descriptions, with no access or
    /// disk check, no sleep assertion, and no disk watcher. Checks the route of each armed track,
    /// then, after the write in progress, saves `session.xml` with `<recording>` on the main
    /// actor, then starts each device writer on the environment HAL. A throw changes nothing.
    func startTake(
        armed: [TrackID], devices: [InputDevice], playhead: Frames, hostTimeNanos: UInt64
    ) async throws(StudioError) -> [String: DeviceWriter] {
        try checkIdle()
        guard pendingTake == nil else { throw .busy }
        let routes = try checkRoutes(session, armed: armed, devices: devices)
        isStarting = true
        let error = await serialized { () async -> StudioError? in
            defer { isStarting = false }
            do throws(StudioError) {
                begin(
                    try saveTakeStart(
                        session, lock: lock, routes: routes, playhead: playhead, hostTimeNanos: hostTimeNanos))
            } catch {
                return error
            }
            return nil
        }
        if let error { throw error }
        return writers
    }

    /// Step 6 of the start order, on the main actor with no throw: the history entry, the
    /// results of earlier takes cleared, the writers, and the transport; then each writer
    /// attaches on its queue.
    private func begin(_ started: StartedTake) {
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
                (arm: $0.arm, channels: $0.route.channels)
            }
            writers[device.uid] = DeviceWriter(
                device: device, tracks: tracks, take: started.take, folder: capture, hal: environment.hal,
                report: report, silenceLimit: environment.silenceLimit,
                firstRecordLimit: environment.firstRecordLimit, ringSeconds: environment.ringSeconds)
        }
        // Every route's device is in `devices` above, so its writer exists.
        armed = started.routes.map { ($0.track, writers[$0.device.uid]!) }
        liveTracks = Dictionary(
            uniqueKeysWithValues: started.routes.map {
                ($0.track, LiveTrack(state: .recording, droppedFrames: 0, peak: 0))
            })
        recordingSince = .now
        transport = .recording(take: started.take)
        for writer in writers.values { writer.start() }
    }

    /// The report closure of the device writers. They call it on their queues, so it is built
    /// in a nonisolated context (AGENTS.md) and hops to the main actor.
    private nonisolated static func reporter(to studio: Studio, generation: Int) -> @Sendable (Report) -> Void {
        { [weak studio] report in Task { @MainActor in studio?.apply(report, generation: generation) } }
    }

    /// A report of another take, also one with the same number, or of a take that ended,
    /// changes nothing.
    private func apply(_ report: Report, generation: Int) {
        guard generation == self.generation else { return }
        switch report {
        case .state(let take, let arm, let state, _):
            guard transport == .recording(take: take), armed.indices.contains(arm - 1) else { return }
            liveTracks[armed[arm - 1].id]?.state = state
            if state == .deviceLost { liveTracks[armed[arm - 1].id]?.peak = 0 }
        case .levels(let take, let peaks, let droppedFrames):
            guard transport == .recording(take: take) else { return }
            for (arm, peak) in peaks where armed.indices.contains(arm - 1) {
                liveTracks[armed[arm - 1].id]?.peak = peak
                liveTracks[armed[arm - 1].id]?.droppedFrames = droppedFrames
            }
        }
    }

    /// Finalize, the marker, and the save off the main actor, then the outcome here.
    private func complete(_ take: Int) async throws(StudioError) {
        transport = .finalizing(take: take)
        let outcome = await completeTake(of: session, lock: lock)
        if let package = outcome.package { url = package }
        transport = .idle
        takeError = outcome.error
        segmentsWithAudio = outcome.segmentsWithAudio
        if let error = outcome.error { throw error }
        history.edit { $0 = outcome.session }
    }

    /// Runs `body` after every package write that started before this call. `body` runs in the
    /// task of the caller, so no actor hop comes between its end and the caller.
    private func serialized<T>(_ body: () async -> T) async -> T {
        let ticket = tickets
        tickets += 1
        await waitForTurn(ticket)
        defer { endTurn() }
        return await body()
    }

    /// Writes a copy of the session off the main actor, after the previous package write. It
    /// takes its ticket now, so a later start or finalize writes after it.
    private func scheduleSave() {
        let (snapshot, lock, save, ticket) = (session, lock, environment.saveSession, tickets)
        tickets += 1
        Task {
            await waitForTurn(ticket)
            switch await writeSession(snapshot, lock: lock, save) {
            case .success(let package):
                url = package
                saveError = nil
            case .failure(let error):
                saveError = error
            }
            endTurn()
        }
    }

    private func waitForTurn(_ ticket: Int) async {
        guard ticket != serving else { return }
        await withCheckedContinuation { waiting[ticket] = $0 }
    }

    private func endTurn() {
        serving += 1
        waiting.removeValue(forKey: serving)?.resume()
    }

    /// Edits, saves, and a new take wait while a take records or finalizes (decision 0004).
    private func checkIdle() throws(StudioError) {
        guard transport == .idle, !isStarting else { throw .busy }
    }
}

public enum StudioError: Error, Hashable, Sendable {
    /// A take records or finalizes, or a new take waits for a pending take.
    case busy
    /// Another studio or the CLI has the package.
    case locked
    /// The armed track has no route.
    case noRoute(TrackID)
    /// The route of the armed track names a device that is not in the list.
    case deviceMissing(TrackID)
    /// The route of the armed track names a channel that the device does not have.
    case channelOutOfRange(TrackID)
    /// Two armed tracks route the same device channel: the first track and the second.
    case channelInUse(TrackID, TrackID)
    case session(SessionError)
    case file(SessionFileError)
    case finalize(FinalizeError)
    /// The front end requests the access and starts again (decision 0013).
    case microphoneAccess(MicrophoneAccess)
    /// Less than 1 GB is free (decision 0004).
    case diskLow
}
