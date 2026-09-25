import DirigibleCore
import Foundation

extension Studio {
    /// Makes a package where nothing exists, then opens it. Throws `.file(.exists)` and changes
    /// nothing when anything is at the path.
    public static func create(
        _ package: URL, sampleRate: Int, recordings: ActiveRecordings? = nil, peakCache: URL? = nil
    ) async throws(StudioError) -> Studio {
        try await createPackage(package, sampleRate: sampleRate)
        return try await open(package, recordings: recordings, peakCache: peakCache)
    }

    /// Records a take for `duration`, then stops it, the call of `dirigible record`. A disk-low
    /// stop, a stop from another caller, or a cancel of this call can end it early; then it
    /// returns soon after that end.
    /// Throws what `startRecording` throws, or the finalize error; then `lastTake` still has the
    /// result and the take stays pending.
    public func record(armed: [TrackID], playhead: Frames, for duration: Duration) async throws(StudioError)
        -> TakeResult
    {
        // Before the start: a conversion that traps after the save of <recording> would leave a
        // pending take. The length saturates, so a very long duration cannot trap.
        let nanos = max(0, duration / .nanoseconds(1))
        let length = nanos < 0x1p64 ? UInt64(nanos) : .max
        // A take with no segment gives its number to the next take, so the number alone cannot
        // tell this take from a new one that another caller starts.
        // The take ends at its start host time + duration, also when the stop comes late.
        let (take, mine) = try await beginRecording(armed: armed, playhead: playhead, length: length)
        let deadline = ContinuousClock.now + duration
        while generation == mine, transport == .recording(take: take), ContinuousClock.now < deadline {
            // A cancel ends the take now, as an early end.
            do { try await Task.sleep(for: min(.milliseconds(50), deadline - .now)) } catch { break }
        }
        if generation == mine, transport == .recording(take: take) { try await stopRecording() }
        // Another stop ended the take; wait for its finalize. The sleep is in a task of its own,
        // so a cancel of this call does not make the wait spin.
        while generation == mine, transport == .finalizing(take: take) {
            await Task { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        // Another caller can start a new take before this call wakes; that start clears the
        // result, and a finalize error is then of the new take.
        guard generation == mine, let lastTake else { throw .busy }
        if let takeError { throw takeError }
        return lastTake
    }

    /// The device writer of `uid` in the take that records. For tests.
    func writer(_ uid: String) -> DeviceWriter? { writers[uid] }

    /// The test seam of decision 0004: starts a take from device descriptions, with no access or
    /// disk check, no sleep assertion, and no disk watcher. Checks the route of each armed track,
    /// then, after the write in progress, saves `session.xml` with `<recording>` on the main
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
        let error = await serialized { () async -> StudioError? in
            defer { isStarting = false }
            let playhead = await takePlayhead(stopped, playhead)
            // After the route checks and before the save, as `beginRecording` (decision 0019).
            await exportEnd()?()
            do throws(StudioError) {
                begin(
                    try saveTakeStart(
                        session, lock: lock, routes: routes, playhead: playhead, hostTimeNanos: hostTimeNanos))
            } catch {
                return error
            }
            isStarting = false
            await handOver()
            return nil
        }
        if let error { throw error }
        return writers
    }

    /// Each check interval: stops the take when the free space is less than the WAV bytes of
    /// the take plus 1 GB. Before the stop, it ends the exports of the other studios to the
    /// volume of the package and checks again. The reads run off the main actor.
    /// It also sets `recordTimeLeft` for the transport bar.
    func watchDisk() -> Task<Void, Never> {
        let (lock, environment, writers) = (lock, environment, Array(writers.values))
        let channels = armed.compactMap { session.track($0.id)?.layout.channelCount }.reduce(0, +)
        let rate = session.sampleRate
        return Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: environment.diskCheckInterval)
                var wav: Int64 = 0
                for writer in writers { wav += await writer.wavBytes() }
                let free = await freeBytes(of: lock, environment)
                // The stop cancels on the main actor, so a tick after it sets nothing.
                guard !Task.isCancelled else { return }
                self?.recordTimeLeft = DirigibleAudio.remainingRecordTime(
                    free: free, wav: wav, channels: channels, rate: rate)
                guard free < wav + diskMargin else { continue }
                // Capture comes first (decision 0019): the next check counts the space again.
                if await self?.endOtherExports(onVolumeOf: lock) == true { continue }
                try? await self?.stop(.diskLow)
                return
            }
        }
    }

    /// The WAV bytes that the finalize of the pending take needs (3 for each 4 CAF bytes, decision
    /// 0013) and the free bytes of the volume now. Nil with no pending take.
    public func pendingSpace() async -> (needed: Int64, free: Int64)? {
        guard let take = pendingTake?.take else { return nil }
        return (await pendingWAVBytes(take: take, of: lock), await freeBytes(of: lock, environment))
    }

    /// The IDs of the clips of take `take` on every track, in segment name order.
    public func clipIDs(ofTake take: Int) -> [ClipID] {
        session.tracks.flatMap(\.clips).compactMap { clip in SegmentName(id: clip.id.rawValue).map { ($0, clip.id) } }
            .filter { $0.0.take == take }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.1)
    }

    /// The record time that the free space gives the armed tracks: 7 bytes for each sample and
    /// channel after 1 GB and the WAV bytes of a pending take (decision 0004). Nil when a track
    /// is not in the session or no track is armed. ponytail: the session rate for every track;
    /// a device at a higher rate uses its CAF bytes faster.
    public func remainingRecordTime(armed: [TrackID]) async -> Duration? {
        var channels = 0
        for id in armed {
            guard let track = session.track(id) else { return nil }
            channels += track.layout.channelCount
        }
        guard channels > 0 else { return nil }
        let free = await freeBytes(of: lock, environment)
        var pending: Int64 = 0
        if let take = pendingTake?.take { pending = await pendingWAVBytes(take: take, of: lock) }
        return DirigibleAudio.remainingRecordTime(
            free: free, wav: pending, channels: channels, rate: session.sampleRate)
    }
}

/// The record time that `free` bytes give `channels` channels at `rate`: 7 bytes for each sample
/// and channel (a CAF and its WAV) after 1 GB and the WAV bytes `wav` (decision 0004). Never
/// below 0.
public func remainingRecordTime(free: Int64, wav: Int64, channels: Int, rate: Int) -> Duration {
    let perSecond = Int64(channels * rate * 7)
    guard perSecond > 0 else { return .zero }
    return .seconds(Double(max(0, free - diskMargin - wav)) / Double(perSecond))
}

/// `Session.create` off the main actor.
@concurrent nonisolated func createPackage(_ package: URL, sampleRate: Int) async throws(StudioError) {
    dispatchPrecondition(condition: .notOnQueue(.main))
    do { try Session.create(at: package, sampleRate: sampleRate) } catch { throw .file(error) }
}

/// The autosave step, off the main actor. Returns the package path that it wrote, in
/// `packageIdentity` form, or the error of the write.
/// A write into a package that moved from `previous` moves its list entry.
@concurrent nonisolated func writeSession(
    _ session: Session, lock: PackageLock, previous: URL, recordings: ActiveRecordings?,
    _ save: @Sendable (Session, PackageLock) throws(SessionFileError) -> URL
) async -> Result<URL, StudioError> {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let package: URL
    do throws(SessionFileError) {
        package = packageIdentity(try save(session, lock))
    } catch {
        return .failure(.file(error))
    }
    if package != previous { recordings?.set(package, active: session.recording != nil, previous: previous) }
    return .success(package)
}
