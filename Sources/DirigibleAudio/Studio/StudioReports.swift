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
            if state == .deviceLost { liveTracks[armed[arm - 1].id]?.peak = 0 }
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
            for (arm, level) in arms where armed.indices.contains(arm - 1) {
                liveTracks[armed[arm - 1].id]?.peak = level.peak
                liveTracks[armed[arm - 1].id]?.droppedFrames = droppedFrames
            }
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
            if state == .deviceLost || state == .retryStopped { liveTracks[id]?.peak = 0 }
        case .levels(_, let arms, _, let droppedFrames):
            for (arm, level) in arms where monitor.tracks.indices.contains(arm - 1) {
                liveTracks[monitor.tracks[arm - 1].id]?.peak = level.peak
                liveTracks[monitor.tracks[arm - 1].id]?.droppedFrames = droppedFrames
            }
        }
    }
}
