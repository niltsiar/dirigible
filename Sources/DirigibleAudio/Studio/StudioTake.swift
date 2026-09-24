import DirigibleCore
import Foundation

extension Studio {
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
        let (take, mine) = try await beginRecording(armed: armed, playhead: playhead)
        // The take ends at its start host time + duration, also when the stop comes late.
        let (end, overflow) = (session.recording?.takeStartHostTimeNanos ?? 0).addingReportingOverflow(length)
        for writer in writers.values { writer.end(atHostNanos: overflow ? .max : end) }
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
        let perSecond = Int64(channels * session.sampleRate * 7)
        guard perSecond > 0 else { return nil }
        let free = await freeBytes(of: url, environment)
        var pending: Int64 = 0
        if let take = pendingTake?.take { pending = await pendingWAVBytes(take: take, in: url) }
        return .seconds(Double(max(0, free - diskMargin - pending)) / Double(perSecond))
    }
}

/// The autosave step, off the main actor. Returns the error of the write, or nil.
@concurrent nonisolated func writeSession(
    _ session: Session, to package: URL, _ save: @Sendable (Session, URL) throws(SessionFileError) -> Void
) async -> StudioError? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    do { try save(session, package) } catch { return .file(error) }
    return nil
}
