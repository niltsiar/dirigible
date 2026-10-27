import DirigibleCore

/// The app source of a writer (decision 0030): its process, output, and silence events. They run
/// on the writer queue, as all writer state.
extension DeviceWriter {
    /// The come back rebuilds of one writer. With the 3 silence rebuilds and the first attach, a
    /// denied track keeps 12 of the 64 inputs of a monitor writer (decision 0015).
    static let silentRetapLimit = 8

    /// A7 and A8: a process-list, default-output, or device-list event of a running app writer.
    /// The found key rebuilds the tap when it has a new process or output, and a slot main
    /// sub-device that is not in the device list rebuilds it (code gate 3 H1); else the slot takes
    /// the found set (fix check 2) and the tap goes on. No output device: lost.
    func appChanged() {
        guard let app, let current = input?.key else { return }
        guard let found = hal.lookUpApp(app, ChannelLayout(channelCount: tracks.routedWidth) ?? .mono) else {
            return lose(.list)
        }
        // H1: a main sub-device that no process reports can leave the device list.
        let mainGone = current.output.map { !hal.deviceExists($0) } ?? false
        guard needsRebuild(current, found.key) || mainGone else {
            // Only the processes change: the aggregate keeps its main sub-device.
            input?.key = AppKey(processes: found.key.processes, output: current.output)
            return reportAppState()
        }
        rebuild(cause: Set(found.key.processes).isSubset(of: current.processes) ? "output" : "processes")
    }

    /// A new tap and aggregate into a new segment, with no gap: a rebuild is not a loss. A
    /// rebuild that fails makes the track lost, and the 1 s retry goes on. `cause` goes to the
    /// journal: `processes`, `output`, `alive`, `active` (`retapSilent()`), or the silence step
    /// (`SilenceCheck.rebuildCause`). A rebuild that is not a silence step rearms the check.
    func rebuild(cause: String, silenceStep: Bool = false) {
        let span = log.begin(.tap, "rebuild-begin", ["app": .text(app ?? ""), "cause": .text(cause)])
        detach()
        if !silenceStep { silence.rearm() }
        tracks.endSegment()
        guard attach() else {
            span.end("rebuild", level: .error, ["cause": .text(cause), "result": .text("lost")])
            return lose(.attachFailed)
        }
        span.end("rebuild", ["cause": .text(cause)])
        reportAppState()
    }

    /// A9: the silence warning and its rebuilds. The playing flag is a lookup of the app.
    func checkSilence() {
        guard let app else { return }
        let layout = ChannelLayout(channelCount: tracks.routedWidth) ?? .mono
        let due = silence.due { hal.lookUpApp(app, layout)?.playing == true }
        if due.warn { log.note(.tap, "silence", ["app": .text(app)]) }
        if due.rebuild { rebuild(cause: silence.rebuildCause, silenceStep: true) } else { reportAppState() }
    }

    /// The come back from System Settings (decision 0015): a new tap for a running monitor writer
    /// whose track shows the silence warning, at most `silentRetapLimit` times for the life of
    /// the writer. Then the Input Levels toggle makes a new writer.
    func retapSilent() {
        guard phase == .running, silentRetaps < Self.silentRetapLimit else { return }
        silentRetaps += 1
        rebuild(cause: "active")
    }

    /// Reports `.waitingForApp` when the app of the current tap has no process, `.noSound` while
    /// the silence warning shows, and `.recording` else: one report for each change.
    func reportAppState() {
        guard app != nil, let key = input?.key else { return }
        let state: LiveTrack.State =
            key.processes.isEmpty ? .waitingForApp : silence.warns ? .noSound : .recording
        guard state != appState else { return }
        appState = state
        for arm in tracks.arms { report(.state(take: tracks.take, arm: arm, state, status: nil)) }
    }
}
