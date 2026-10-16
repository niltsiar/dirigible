import Atomics
import DirigibleCore

/// The waits of one take start that a stop ends at once (decision 0030). On the main actor.
@MainActor final class WaitCut {
    private var waits: [@Sendable () -> Void] = []
    private(set) var isCut = false

    /// Ends each wait now, and each wait that starts after this call at its start.
    func cut() {
        isCut = true
        for end in waits { end() }
        waits = []
    }

    fileprivate func add(_ end: @escaping @Sendable () -> Void) {
        if isCut { end() } else { waits.append(end) }
    }
}

/// Resumes a continuation once: the first of the work, the deadline, and the cut wins.
private final class Once<T: Sendable>: Sendable {
    private let resumed = ManagedAtomic(false)
    private let continuation: CheckedContinuation<T?, Never>

    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

    func resume(_ value: T?) {
        guard resumed.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
        else { return }
        continuation.resume(returning: value)
    }
}

/// The result of `work`, or nil at `deadline` or at the cut, whichever comes first. A missed
/// `work` goes on in its own task, and its result goes nowhere, so a writer step that waits on
/// its queue (`started()`, `finish()`) still runs when the queue answers. A task group does not
/// fit: it waits for each child, and a continuation does not cancel.
@MainActor func bounded<T: Sendable>(
    by deadline: ContinuousClock.Instant, cut: WaitCut? = nil, _ work: @escaping @Sendable () async -> T
) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = Once(continuation)
        let timer = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            once.resume(nil)
        }
        cut?.add {
            timer.cancel()
            once.resume(nil)
        }
        Task {
            once.resume(await work())
            timer.cancel()
        }
    }
}

/// The results of `work` for each writer that answered by `deadline` or the cut. Each `work`
/// starts at once, so a writer that does not answer takes no time from the others.
@MainActor func boundedEach<T: Sendable>(
    _ writers: [DeviceWriter], by deadline: ContinuousClock.Instant, cut: WaitCut? = nil,
    _ work: @escaping @Sendable (DeviceWriter) async -> T
) async -> [ObjectIdentifier: T] {
    let results = Answers<T>()
    let tasks = writers.map { writer in
        Task { @MainActor in results.values[ObjectIdentifier(writer)] = await work(writer) }
    }
    _ = await bounded(by: deadline, cut: cut) { for task in tasks { await task.value } }
    return results.values
}

@MainActor private final class Answers<T> {
    var values: [ObjectIdentifier: T] = [:]
}

/// A writer of the pending take that did not finish by the stop deadline, with its device UID and
/// the track of each of its arms: the stop clears `armed`, and Retry Finalize maps the late gaps
/// through it.
struct UnfinishedWriter {
    let writer: DeviceWriter
    let uid: String
    let tracks: [Int: TrackID]
}

extension Studio {
    /// Starts the app writers after the first attach try of each device writer (A5): a tap that
    /// starts before the microphone of a Bluetooth headset can stop its IO ([MT-ARCH] in
    /// `docs/research/process-taps.md`). The wait ends at the start deadline or at a stop. The
    /// tracks of a device writer that is still in its first attach at the deadline show
    /// `.notStarted`, and its first report replaces it. A lost track keeps `.deviceLost`. After a
    /// stop, no app writer starts.
    func startApps(by deadline: ContinuousClock.Instant, cut: WaitCut) async {
        let devices = writers.values.filter { $0.app == nil }
        let started = await boundedEach(devices, by: deadline, cut: cut) { await $0.started() }
        guard !cut.isCut else { return }
        for writer in devices where started[ObjectIdentifier(writer)] == nil && writer.startState == .notAttached {
            for track in armed where track.writer === writer && liveTracks[track.id]?.state != .deviceLost {
                liveTracks[track.id]?.state = .notStarted
            }
        }
        for writer in writers.values where writer.app != nil { writer.start() }
    }

    /// Finishes the device writers, then the app writers, by `deadline`, and returns the gaps of
    /// the take and the writers that did not finish. An app writer can wait for the prompt: a
    /// device writer closes first, so its input stops at the stop (code gate 2 F1). A writer in
    /// `abandoned` never attached: it holds no audio, so each of its tracks gets a gap and the
    /// stop does not wait for it.
    func finishWriters(by deadline: ContinuousClock.Instant, abandoned: [DeviceWriter]) async -> (
        gaps: [TrackID: TakeResult.Gap], unfinished: [UnfinishedWriter]
    ) {
        var gaps: [TrackID: TakeResult.Gap] = [:]
        var unfinished: [UnfinishedWriter] = []
        let isAbandoned = { (writer: DeviceWriter) in abandoned.contains { $0 === writer } }
        let pairs = Array(writers)
        let order = pairs.filter { $0.value.app == nil } + pairs.filter { $0.value.app != nil }
        let answers = await boundedEach(order.map(\.value).filter { !isAbandoned($0) }, by: deadline) {
            await $0.finish()
        }
        for (uid, writer) in order {
            let tracks = Dictionary(
                uniqueKeysWithValues: armed.indices.filter { armed[$0].writer === writer }.map {
                    ($0 + 1, armed[$0].id)
                })
            if isAbandoned(writer) {
                for track in tracks.values { gaps[track] = .deviceLost }
            } else if let finished = answers[ObjectIdentifier(writer)] {
                for (arm, gap) in finished { gaps[armed[arm - 1].id] = gap }
            } else {
                unfinished.append(UnfinishedWriter(writer: writer, uid: uid, tracks: tracks))
            }
        }
        return (gaps, unfinished)
    }

    /// Retry Finalize waits for the writers that the stop left unfinished, by `deadline`, and
    /// adds their gaps and their silent tracks to `lastTake`. The device of a writer that finished
    /// gets its monitor again. Returns `.writerDidNotStop` when one still does not answer.
    func finishUnfinished(by deadline: ContinuousClock.Instant) async -> StudioError? {
        var late: [TrackID: TakeResult.Gap] = [:]
        var silent: [TrackID: String] = [:]
        var still: [UnfinishedWriter] = []
        let answers = await boundedEach(unfinishedWriters.map(\.writer), by: deadline) { await $0.finish() }
        for entry in unfinishedWriters {
            if let finished = answers[ObjectIdentifier(entry.writer)] {
                for (arm, gap) in finished { if let track = entry.tracks[arm] { late[track] = gap } }
                if let app = await entry.writer.silentApp() { for track in entry.tracks.values { silent[track] = app } }
            } else {
                still.append(entry)
            }
        }
        unfinishedWriters = still
        if let last = lastTake {
            lastTake = TakeResult(
                take: last.take, end: last.end, gaps: last.gaps.merging(late) { first, _ in first },
                droppedFrames: last.droppedFrames, silent: last.silent.merging(silent) { first, _ in first })
        }
        if !answers.isEmpty { await monitorTurns.run { await applyMonitor() } }
        return still.first.map { .writerDidNotStop($0.writer.name) }
    }

    /// The hand-over to a take (decision 0015), after `startApps`: in one monitor turn, it
    /// finishes each monitor writer, so the device keeps running (probe Q1). Each wait ends at the
    /// start deadline or at a stop. A turn that comes after them waits for no writer: it finishes
    /// each monitor writer later. `begin` replaced the entries of `liveTracks` already.
    func handOver(by deadline: ContinuousClock.Instant, cut: WaitCut) async {
        let turn = Task { @MainActor in
            await monitorTurns.run {
                let released = monitors.values.map(\.writer)
                monitors = [:]
                let late = cut.isCut || ContinuousClock.now >= deadline
                let answers = late ? [:] : await boundedEach(released, by: deadline, cut: cut) { await $0.finish() }
                for writer in released where answers[ObjectIdentifier(writer)] == nil { writer.finishLater() }
            }
        }
        _ = await bounded(by: deadline, cut: cut) { await turn.value }
    }

    /// The armed app tracks whose writer showed the silence warning and got no sound, each with
    /// the app name (A9). Call it after each writer finished; it skips the writers of `skipping`,
    /// whose queue can still wait.
    func silentTracks(skipping: [DeviceWriter]) async -> [TrackID: String] {
        var silent: [TrackID: String] = [:]
        for (track, writer) in armed where !skipping.contains(where: { $0 === writer }) {
            if let app = await writer.silentApp() { silent[track] = app }
        }
        return silent
    }
}
