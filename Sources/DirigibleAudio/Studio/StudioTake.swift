import DirigibleCore
import Foundation

extension Studio {
    /// Makes a package where nothing exists, then opens it. Throws `.file(.exists)` and changes
    /// nothing when anything is at the path.
    public static func create(
        _ package: URL, sampleRate: Int, recordings: ActiveRecordings? = nil, peakCache: URL? = nil,
        log: DiagnosticLog = .disabled
    ) async throws(StudioError) -> Studio {
        try await createPackage(package, sampleRate: sampleRate)
        return try await open(package, recordings: recordings, peakCache: peakCache, log: log)
    }

    /// Records a take for `duration`, then stops it, the call of `dirigible record`. With
    /// `preRoll`, the take plays the pre-roll first, as `startRecording`. A disk-low stop, a stop
    /// from another caller, or a cancel of this call can end it early; then it returns soon after
    /// that end. It returns after the raw sweep job (decision 0071) of the take.
    /// Throws what `startRecording` throws, or the finalize error; then `lastTake` still has the
    /// result and the take stays pending.
    public func record(armed: [TrackID], playhead: Frames, for duration: Duration, preRoll: Int? = nil)
        async throws(StudioError) -> TakeResult
    {
        // The generation, not the take number, tells this take from a new one that another
        // caller starts. The timer of the timed start stops the take (`timedTakeStop`).
        let (take, mine) = try await beginTimed(armed: armed, playhead: playhead, duration: duration, preRoll: preRoll)
        while generation == mine, transport == .recording(take: take) {
            // A cancel ends the take now, as an early end.
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        if generation == mine, transport == .recording(take: take) { try await stopRecording() }
        // Another stop ended the take; wait for its finalize. A start of another caller sets
        // `isStarting` before its first suspension and changes `generation` only at `begin`, so
        // also wait until that start begins its take or fails. The sleep is in a task of its own,
        // so a cancel of this call does not make the wait spin.
        while generation == mine, transport == .finalizing(take: take) || isStarting {
            await Task { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        await rawSweep
        // Another caller can start a new take before this call wakes; that start clears the
        // result, and a finalize error is then of the new take. A start that fails keeps both.
        guard generation == mine, let lastTake else { throw .busy }
        if let takeError { throw takeError }
        return lastTake
    }

    /// Runs finalize again for the pending take (decision 0004). With no pending take, it does
    /// nothing. A success records one undo entry. A failure keeps the take pending and throws.
    /// With `leavingUnreadable`, a segment that throws `.segmentUnreadable` stays unplaced and
    /// the take ends without it (decision 0021). Only a choice of the user sets it. It first waits
    /// for each writer that the stop left unfinished, until `stopLimit` after the call; a writer
    /// that still does not answer throws `.writerDidNotStop` with no finalize (decision 0030).
    public func retryFinalize(leavingUnreadable: Bool = false) async throws(StudioError) {
        try checkIdle()
        guard let take = pendingTake?.take else { return }
        let deadline = ContinuousClock.now + environment.stopLimit
        transport = .finalizing(take: take)
        environment.log.note(.take, "retry-finalize", ["unfinished": .number(Int64(unfinishedWriters.count))])
        let error = await serialized { () async -> StudioError? in
            if let error = await finishUnfinished(by: deadline) {
                takeError = error
                transport = .idle
                return error
            }
            do throws(StudioError) {
                try await completeLogged(take, leavingUnreadable: leavingUnreadable)
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
    /// releases its devices (decision 0015). With `preRoll` (whole seconds), the Player plays the
    /// take mix from that time before the playhead, and the take starts at the heard playhead
    /// (decision 0070).
    public func startRecording(armed: [TrackID], playhead: Frames? = nil, preRoll: Int? = nil)
        async throws(StudioError)
    {
        _ = try await beginRecording(armed: armed, playhead: playhead, preRoll: preRoll)
    }

    /// `startRecording` for `duration`, the take of an agent (decision 0048). Each writer ends at
    /// the take start H_T + `duration`, and `takeTimer` stops the take after that end and the
    /// frames in flight (`timedTakeStop`). A stop before cancels the timer. Returns the take.
    public func startRecording(armed: [TrackID], playhead: Frames?, for duration: Duration, preRoll: Int? = nil)
        async throws(StudioError) -> Int
    {
        try await beginTimed(armed: armed, playhead: playhead, duration: duration, preRoll: preRoll).take
    }

    /// The timed start of `startRecording(armed:playhead:for:preRoll:)` and `record`, with the
    /// generation.
    private func beginTimed(armed: [TrackID], playhead: Frames?, duration: Duration, preRoll: Int?)
        async throws(StudioError) -> (take: Int, generation: Int)
    {
        // Before the start: a conversion that traps after the save of <recording> would leave a
        // pending take.
        let length = Self.nanos(duration)
        let (take, mine, stop) = try await beginRecording(
            armed: armed, playhead: playhead, length: length, preRoll: preRoll)
        // A stop can end the take before the start returns: then no timer.
        guard transport == .recording(take: take), let stop else { return (take, mine) }
        let (wait, clock) = (environment.takeStop, environment.hostNanos)
        takeTimer = Task { [weak self] in
            await wait(stop, clock)
            guard !Task.isCancelled else { return }
            try? await self?.stopRecording()
        }
        return (take, mine)
    }

    /// The nanoseconds of `duration`, saturated, so a very long duration cannot trap.
    private static func nanos(_ duration: Duration) -> UInt64 {
        let nanos = max(0, duration / .nanoseconds(1))
        return nanos < 0x1p64 ? UInt64(nanos) : .max
    }

    /// `startRecording`, which also returns the take and the generation that it started. A stop
    /// can end that take before this call returns. With `length` (nanoseconds), each writer
    /// writes no record at or after the take start + `length`, and `stop` is the host time of the
    /// timed stop (`timedTakeStop`). The end is set before the hand-over waits, so no drain writes
    /// past it. `beginRecording` writes its first and last line.
    func startSteps(armed: [TrackID], playhead: Frames?, length: UInt64?, preRoll: Int?) async throws(StudioError) -> (
        take: Int, generation: Int, stop: UInt64?
    ) {
        try checkIdle()
        guard pendingTake == nil else { throw .busy }
        isStarting = true
        let stopped = endPlayForTake()
        await rawSweepsEnded()
        let queued = ContinuousClock.now
        // The whole start is one step of the chain, so a stop or a settle never sees half of it.
        let result = await serialized { () async -> Result<(take: Int, generation: Int, stop: UInt64?), StudioError> in
            defer { isStarting = false }
            environment.log.note(.take, "write-chain", ["ms": .since(queued)])
            let playhead = await takePlayhead(stopped, playhead)
            let (started, free): (StartedTake, Int64)
            do throws(StudioError) {
                (started, free) = try await prepareTake(
                    of: session, lock: lock, armed: armed, playhead: playhead, environment: environment,
                    recordings: recordings, endExport: exportEnd(),
                    anchor: preRoll.map { preRollStep(seconds: $0, at: playhead, armed: armed) })
            } catch {
                if preRoll != nil { await endFaultedPreRoll(at: playhead) }
                return .failure(error)
            }
            let deadline = ContinuousClock.now + environment.startLimit
            begin(started)
            let cut = WaitCut()
            startCut = cut
            var stop: UInt64?
            if let length {
                let (sum, overflow) = (started.session.recording?.takeStartHostTimeNanos ?? 0)
                    .addingReportingOverflow(length)
                let end = overflow ? UInt64.max : sum
                for writer in writers.values { writer.end(atHostNanos: end) }
                stop = timedTakeStop(end: end, devices: started.routes.map(\.device))
            }
            let channels = self.armed.compactMap { session.track($0.id)?.layout.channelCount }.reduce(0, +)
            recordTimeLeft = DirigibleAudio.remainingRecordTime(
                free: free, wav: 0, channels: channels, rate: session.sampleRate)
            let assertion = environment.log.begin(.take, "sleep-assertion-begin")
            sleepAssertion = environment.makeSleepAssertion()
            assertion.end("sleep-assertion")
            diskWatcher = watchDisk(channels: channels)
            // A stop from now on waits for this step and does not throw `.busy`.
            isStarting = false
            await environment.afterStart()
            await startApps(by: deadline, cut: cut)
            await handOver(by: deadline, cut: cut)
            startCut = nil
            return .success((started.take, generation, stop))
        }
        return try result.get()
    }

    /// Stops the take: drains and closes each device writer, starts the monitor of the request
    /// again, then finalizes and saves (0004), then levels the take clips and saves again (0031).
    /// With no take, it does nothing. A success records one undo entry, and one more when the
    /// level changes a gain. A failure keeps the take pending and throws. A writer that never
    /// attached is given up, and the stop waits for each other writer until one deadline: the call
    /// plus `stopLimit`. When a writer misses it, no finalize runs: the take stays pending with its
    /// audio on disk, and the stop throws `.writerDidNotStop` (decision 0030).
    public func stopRecording() async throws(StudioError) {
        try await stop(.requested)
    }

    func stop(_ end: TakeEnd) async throws(StudioError) {
        if case .finalizing = transport { throw .busy }
        guard !isStarting else { throw .busy }
        guard case .recording(let take) = transport else { return }
        environment.log.note(.take, "stop-request", ["take": .number(Int64(take)), "end": .text("\(end)")])
        let called = ContinuousClock.now
        transport = .finalizing(take: take)
        // E1: the take ends now on every track, also while an app attach waits for the prompt.
        let now = hostNanosNow()
        stopLive()
        diskWatcher?.cancel()
        diskWatcher = nil
        takeTimer?.cancel()
        takeTimer = nil
        // A stop before T gives 0 s.
        let seconds = session.recording.map { Double(now - min(now, $0.takeStartHostTimeNanos)) / 1e9 }
        for writer in writers.values { writer.end(atHostNanos: now) }
        // After the take end, so the Player stop does not make the take longer. The playhead of a
        // stop before T is T (decision 0070).
        if let recording = session.recording, recording.isPreRoll { await endPreRoll(at: recording.playheadFrame) }
        // A writer that never attached holds no audio, so the stop does not wait for it; its queued
        // finish runs after its attach returns. The start step returns at once.
        let abandoned = writers.values.filter { $0.abandon() }
        for writer in abandoned {
            writer.finishLater()
            environment.log.note(.take, "abandoned", ["writer": .text(writer.name)])
        }
        startCut?.cut()
        let error = await serialized { () async -> StudioError? in
            let deadline = called + environment.stopLimit
            let (gaps, unfinished) = await finishWriters(by: deadline, abandoned: abandoned)
            let silent = await silentTracks(skipping: abandoned + unfinished.map(\.writer))
            let dropped = armed.compactMap { track in
                track.writer.droppedFrames > 0 ? (track.id, track.writer.droppedFrames) : nil
            }
            let wav = writers.values.reduce(Int64(0)) { $0 + $1.wavBytes }
            lastTake = TakeResult(
                take: take, end: end, gaps: gaps, droppedFrames: Dictionary(uniqueKeysWithValues: dropped),
                silent: silent, lateStarts: Set(armed.filter { $0.writer.startedLate }.map(\.id)))
            writers = [:]
            armed = []
            liveTracks = [:]
            recordingSince = nil
            recordTimeLeft = nil
            // Before the monitor: it skips the device of each unfinished writer.
            unfinishedWriters = unfinished
            // The come back returns its monitor turn before the finalize (decision 0015).
            await monitorTurns.run { await applyMonitor() }
            defer { sleepAssertion = nil }
            if let late = unfinished.first {
                logLate(unfinished)
                takeError = .writerDidNotStop(late.writer.name)
                dropLiveTake()
                transport = .idle
                return takeError
            }
            do throws(StudioError) {
                try await completeLogged(take, level: true, wav: wav, seconds: seconds)
            } catch {
                return error
            }
            return nil
        }
        if let error { throw error }
    }

    /// Finalize, the marker, the save, and the level of a stop off the main actor, then the outcome.
    /// Call it only in a `serialized` turn, so its save does not race another package write.
    func complete(_ take: Int, leavingUnreadable: Bool = false, level: Bool = false) async throws(StudioError) {
        transport = .finalizing(take: take)
        await environment.beforeFinalize()
        let outcome = await completeTake(
            of: session, lock: lock, recordings: recordings, previous: url, leavingUnreadable: leavingUnreadable,
            level: level)
        takeError = outcome.error
        if outcome.error == nil { takeEnded(outcome.session) } else { dropLiveTake() }
        try apply(outcome)
        sweepRaw()
    }

    /// Places an unplaced segment (decision 0021): on the track of its arm at its recorded time
    /// (the take anchor), or on `track` and at `start` when given. A negative `start` throws
    /// `.segment(segment, .session(.frameOutOfRange))`. A running play stops first, as
    /// at a take start. The conversion and the save run off the main actor; meanwhile every other
    /// entry point throws `.busy`. A success records one undo entry and returns the clip ID, or
    /// nil when the segment has no frame after the take playhead: then it is a pool file with no
    /// clip. A throw changes nothing.
    public func place(_ segment: SegmentName, on track: TrackID? = nil, at start: Frames? = nil)
        async throws(StudioError) -> ClipID?
    {
        try checkIdle()
        guard unplacedSegments.contains(segment) else { throw .segment(segment, .notUnplaced) }
        // The per-segment finalize moves an aligned start before the floor into the offset; a
        // given start is a timeline position, so it cannot be negative.
        if let start, start < .zero { throw .segment(segment, .session(.frameOutOfRange)) }
        let stopped = endPlayForTake()
        transport = .placing(segment)
        let error = await serialized { () async -> StudioError? in
            _ = await takePlayhead(stopped, nil)  // The Player stops.
            await environment.beforeFinalize()
            let outcome = await completePlacement(
                segment, track: track, start: start, of: session, lock: lock, environment: environment,
                recordings: recordings, previous: url)
            do throws(StudioError) { try apply(outcome) } catch { return error }
            sweepRaw()
            return nil
        }
        if let error { throw error }
        return session.clip(ClipID(segment.stem)).map { _ in ClipID(segment.stem) }
    }

    /// The device writer of `uid` in the take that records. For tests.
    func writer(_ uid: String) -> DeviceWriter? { writers[uid] }

    /// The test seam of decision 0004: starts a take from device descriptions, with no access or
    /// disk check, no sleep assertion, and no disk watcher. Checks the route of each armed track,
    /// then, after the write in progress, saves `session.xml` with `<recording>` off the main
    /// actor, then starts each device writer on the environment HAL. A throw changes nothing, but
    /// a running export of this studio or of another studio ends before the save.
    func startTake(
        armed: [TrackID], devices: [InputDevice], playhead: Frames? = nil, hostTimeNanos: UInt64
    ) async throws(StudioError) -> [String: DeviceWriter] {
        try checkIdle()
        guard pendingTake == nil else { throw .busy }
        let routes = try checkRoutes(session, armed: armed, devices: devices)
        isStarting = true
        let stopped = endPlayForTake()
        await rawSweepsEnded()
        let error = await serialized { () async -> StudioError? in
            defer { isStarting = false }
            let playhead = await takePlayhead(stopped, playhead)
            // After the route checks and before the save, as `beginRecording` (decision 0019).
            await exportEnd()?()
            do throws(StudioError) {
                begin(
                    try await saveTestTakeStart(
                        session, lock: lock, routes: routes, playhead: playhead, hostTimeNanos: hostTimeNanos,
                        environment: environment))
            } catch {
                return error
            }
            isStarting = false
            let deadline = ContinuousClock.now + environment.startLimit
            let cut = WaitCut()
            startCut = cut
            await startApps(by: deadline, cut: cut)
            await handOver(by: deadline, cut: cut)
            startCut = nil
            return nil
        }
        if let error { throw error }
        return writers
    }

    /// The IDs of the clips of take `take` on every track, in segment name order.
    public func clipIDs(ofTake take: Int) -> [ClipID] {
        session.tracks.flatMap(\.clips).compactMap { clip in SegmentName(id: clip.id.rawValue).map { ($0, clip.id) } }
            .filter { $0.0.take == take }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.1)
    }
}

/// `Session.create` off the main actor.
@concurrent nonisolated func createPackage(_ package: URL, sampleRate: Int) async throws(StudioError) {
    dispatchPrecondition(condition: .notOnQueue(.main))
    do { try Session.create(at: package, sampleRate: sampleRate) } catch { throw .file(error) }
}

/// The autosave step, off the main actor. Returns the package path that it wrote, in
/// `packageIdentity` form, and the backups after the write (decision 0043), or the error of the
/// write. A write into a package that moved from `previous` moves its list entry.
@concurrent nonisolated func writeSession(
    _ session: Session, lock: PackageLock, previous: URL, recordings: ActiveRecordings?,
    _ save: @Sendable (Session, PackageLock) async throws(SessionFileError) -> URL
) async -> Result<(package: URL, backups: [Backup]), StudioError> {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let written: URL
    do throws(SessionFileError) {
        written = try await save(session, lock)
    } catch {
        return .failure(.file(error))
    }
    let package = packageIdentity(written)
    if package != previous { recordings?.set(package, active: session.recording != nil, previous: previous) }
    return .success((package, Backup.all(in: written)))
}
