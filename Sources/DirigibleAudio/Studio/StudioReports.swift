import DirigibleCore

extension Studio {
    /// The report closure of the device writers. They call it on their queues, so it is built
    /// in a nonisolated context (AGENTS.md) and hops to the main actor.
    nonisolated static func reporter(to studio: Studio, generation: Int) -> @Sendable (Report) -> Void {
        { [weak studio] report in Task { @MainActor in studio?.apply(report, generation: generation) } }
    }

    /// A report of another take, also one with the same number, or of a take that ended,
    /// changes nothing.
    func apply(_ report: Report, generation: Int) {
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
        case .levels(_, let peaks, let droppedFrames):
            for (arm, peak) in peaks where monitor.tracks.indices.contains(arm - 1) {
                liveTracks[monitor.tracks[arm - 1].id]?.peak = peak
                liveTracks[monitor.tracks[arm - 1].id]?.droppedFrames = droppedFrames
            }
        }
    }
}
