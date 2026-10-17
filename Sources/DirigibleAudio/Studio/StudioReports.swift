import DirigibleCore

extension Studio {
    /// The report closure of the device writers. They call it on their queues, so it is built
    /// in a nonisolated context (AGENTS.md) and hops to the main actor.
    nonisolated static func reporter(to studio: Studio, generation: Int) -> @Sendable (Report) -> Void {
        { [weak studio] report in Task { @MainActor in studio?.apply(report, generation: generation) } }
    }

    /// A report of another take, also one with the same number, or of a take that ended,
    /// changes nothing. The live store takes `.levels` until the hand-off (`Studio+Live.swift`).
    func apply(_ report: Report, generation: Int) {
        guard generation == self.generation else { return }
        switch report {
        case .state(let take, let arm, let state, _):
            guard transport == .recording(take: take), armed.indices.contains(arm - 1) else { return }
            liveTracks[armed[arm - 1].id]?.state = state
            if state == .deviceLost {
                liveTracks[armed[arm - 1].id]?.peak = 0
                liveTracks[armed[arm - 1].id]?.shortTerm = nil
            }
        case .levels(let take, let arms, let latencyNanos, let droppedFrames):
            // The live store takes the final drains of the finalize too, through its own arm map.
            if transport == .recording(take: take) || transport == .finalizing(take: take) {
                let now = hostNanosNow()
                for (arm, level) in arms {
                    if let track = live.arms[arm] {
                        addLive(track: track, level: level, latencyNanos: latencyNanos, now: now)
                    }
                }
            }
            guard transport == .recording(take: take) else { return }
            liveTracks = metered(
                arms.compactMap { armed.indices.contains($0 - 1) ? (armed[$0 - 1].id, $1) : nil }, droppedFrames)
        }
    }
}

extension Studio {
    /// The report closure of a monitor writer, built in a nonisolated context as `reporter`.
    nonisolated static func monitorReporter(to studio: Studio, number: Int, uid: String) -> @Sendable (Report) -> Void {
        { [weak studio] report in Task { @MainActor in studio?.applyMonitor(report, number: number, uid: uid) } }
    }

    /// A report of a monitor writer that is not the current one of `uid`, or that comes while
    /// take writers exist, changes nothing. A come back (`.recording`) is `.monitoring`.
    func applyMonitor(_ report: Report, number: Int, uid: String) {
        guard writers.isEmpty, let monitor = monitors[uid], monitor.number == number else { return }
        switch report {
        case .state(_, let arm, let state, _):
            guard monitor.tracks.indices.contains(arm - 1) else { return }
            let id = monitor.tracks[arm - 1].id
            liveTracks[id]?.state = state == .recording ? .monitoring : state
            if state == .deviceLost || state == .retryStopped {
                liveTracks[id]?.peak = 0
                liveTracks[id]?.shortTerm = nil
            }
        case .levels(_, let arms, _, let droppedFrames):
            let tracks = monitor.tracks
            liveTracks = metered(
                arms.compactMap { tracks.indices.contains($0 - 1) ? (tracks[$0 - 1].id, $1) : nil }, droppedFrames)
        }
    }
}

extension Studio {
    /// `liveTracks` with the levels of one report: one write for the report, so the `didSet` of
    /// `liveTracks` runs once.
    fileprivate func metered(_ levels: [(TrackID, ArmLevel)], _ droppedFrames: Int) -> [TrackID: LiveTrack] {
        var tracks = liveTracks
        for (id, level) in levels {
            tracks[id]?.peak = level.peak
            tracks[id]?.shortTerm = level.shortTerm
            tracks[id]?.droppedFrames = droppedFrames
        }
        return tracks
    }
}
