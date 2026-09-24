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
