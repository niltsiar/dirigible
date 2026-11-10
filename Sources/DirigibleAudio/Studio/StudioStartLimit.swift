import Atomics
import DirigibleCore
import os

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
/// fit: it waits for each child, and a continuation does not cancel. The deadline and the answer
/// resume off the main actor, so a main-actor hold delays only the return to the caller.
@MainActor func bounded<T: Sendable>(
    by deadline: ContinuousClock.Instant, cut: WaitCut? = nil, _ work: @escaping @Sendable () async -> T
) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = Once(continuation)
        let timer = Task { @concurrent in
            try? await Task.sleep(until: deadline, clock: .continuous)
            once.resume(nil)
        }
        cut?.add {
            timer.cancel()
            once.resume(nil)
        }
        Task { @concurrent in
            once.resume(await work())
            timer.cancel()
        }
    }
}

/// The results of `work` for each writer that answered by `deadline` or the cut. Each `work`
/// starts at once off the main actor and keeps its answer when it ends, so a writer that does not
/// answer takes no time from the others, and a main-actor hold does not delay a writer step.
@MainActor func boundedEach<T: Sendable>(
    _ writers: [DeviceWriter], by deadline: ContinuousClock.Instant, cut: WaitCut? = nil,
    _ work: @escaping @Sendable (DeviceWriter) async -> T
) async -> [ObjectIdentifier: T] {
    let answers = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: T]())
    let tasks = writers.map { writer in
        Task { @concurrent in
            let answer = await work(writer)
            answers.withLock { $0[ObjectIdentifier(writer)] = answer }
        }
    }
    _ = await bounded(by: deadline, cut: cut) { for task in tasks { await task.value } }
    return answers.withLock { $0 }
}

/// A writer of the pending take that did not finish by the stop deadline, with its device UID and
/// the track of each of its arms: the stop clears `armed`, and Retry Finalize maps the late gaps
/// through it. `called` is the stop call, from which each finish line counts its ms.
struct UnfinishedWriter {
    let writer: DeviceWriter
    let uid: String
    let tracks: [Int: TrackID]
    let called: ContinuousClock.Instant
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
        let missed = devices.filter { started[ObjectIdentifier($0)] == nil && $0.startState == .notAttached }
        if !missed.isEmpty {
            let names = missed.map(\.name).joined(separator: ",")
            environment.log.note(.take, "start-deadline", level: .error, ["missed": .text(names)])
        }
        for writer in missed {
            for (index, track) in armed.enumerated()
            where track.writer === writer && liveTracks[track.id]?.state != .deviceLost {
                liveTracks[track.id]?.state = .notStarted
                environment.log.note(.take, "arm-not-started", ["arm": .number(Int64(index + 1))])
            }
        }
        for writer in writers.values where writer.app != nil { writer.start() }
        environment.log.note(.take, "apps-started", ["missed": .number(Int64(missed.count))])
    }

    /// Finishes each writer by `deadline`, and returns the gaps of the take and the writers that
    /// did not finish. The stop starts each finish at its call `called` on the writer queue, and a
    /// writer is on time when its queue ended the finish by `deadline`, also when this call reads
    /// it later; a deadline that is past at the call arms no wait. The stop time
    /// (`end(atHostNanos:)`) ends each track at the click, so a writer that finishes late records
    /// nothing after it. A writer in `abandoned` never attached: it holds no audio, so each of its
    /// tracks gets a gap and the stop does not wait for it. Each other writer gets its
    /// `take writer-finished` line now, or when its finish ends.
    func finishWriters(
        from called: ContinuousClock.Instant, by deadline: ContinuousClock.Instant, abandoned: [DeviceWriter]
    ) async -> (gaps: [TrackID: TakeResult.Gap], unfinished: [UnfinishedWriter]) {
        let log = environment.log
        var gaps: [TrackID: TakeResult.Gap] = [:]
        var unfinished: [UnfinishedWriter] = []
        let isAbandoned = { (writer: DeviceWriter) in abandoned.contains { $0 === writer } }
        if ContinuousClock.now < deadline {
            _ = await boundedEach(writers.values.filter { !isAbandoned($0) }, by: deadline) { await $0.finish() }
        }
        for (uid, writer) in writers {
            let tracks = Dictionary(
                uniqueKeysWithValues: armed.indices.filter { armed[$0].writer === writer }.map {
                    ($0 + 1, armed[$0].id)
                })
            if isAbandoned(writer) {
                for track in tracks.values { gaps[track] = .deviceLost }
                continue
            }
            let record = writer.finishRecord
            if record != nil {
                noteFinished(writer, since: called, log)
            } else {
                Task { @concurrent in
                    await writer.finish()
                    noteFinished(writer, since: called, log)
                }
            }
            if let record, record.at <= deadline {
                for (arm, gap) in record.gaps { gaps[armed[arm - 1].id] = gap }
            } else {
                unfinished.append(UnfinishedWriter(writer: writer, uid: uid, tracks: tracks, called: called))
            }
        }
        return (gaps, unfinished)
    }

    /// Retry Finalize waits for the writers that the stop left unfinished, by `deadline`, and
    /// adds their gaps and their silent tracks to `lastTake`. A writer is on time when its queue
    /// ended the finish by `deadline`; a deadline that is past at the call arms no wait. The device
    /// of a writer that finished gets its monitor again. Returns `.writerDidNotStop` when one is
    /// still late.
    func finishUnfinished(by deadline: ContinuousClock.Instant) async -> StudioError? {
        var late: [TrackID: TakeResult.Gap] = [:]
        var silent: [TrackID: String] = [:]
        var still: [UnfinishedWriter] = []
        if ContinuousClock.now < deadline {
            _ = await boundedEach(unfinishedWriters.map(\.writer), by: deadline) { await $0.finish() }
        }
        var answered = false
        for entry in unfinishedWriters {
            let record = entry.writer.finishRecord
            noteFinished(entry.writer, since: entry.called, environment.log)
            guard let record, record.at <= deadline else {
                still.append(entry)
                continue
            }
            answered = true
            for (arm, gap) in record.gaps { if let track = entry.tracks[arm] { late[track] = gap } }
            if let app = await entry.writer.silentApp() { for track in entry.tracks.values { silent[track] = app } }
        }
        unfinishedWriters = still
        logLate(still)
        if let last = lastTake {
            lastTake = TakeResult(
                take: last.take, end: last.end, gaps: last.gaps.merging(late) { first, _ in first },
                droppedFrames: last.droppedFrames, silent: last.silent.merging(silent) { first, _ in first })
        }
        if answered { await monitorTurns.run { await applyMonitor() } }
        return still.first.map { .writerDidNotStop($0.writer.name) }
    }

    /// The hand-over to a take (decision 0015), after `startApps`: in one monitor turn, it
    /// finishes each monitor device writer, so the device keeps running (probe Q1). Each wait ends
    /// at the start deadline or at a stop. A monitor app writer finishes later with no wait: its
    /// attach can wait at the System Audio Recording prompt (decision 0030 Start). A turn that
    /// comes after the deadline waits for no writer: it finishes each monitor writer later.
    /// `begin` replaced the entries of `liveTracks` already.
    func handOver(by deadline: ContinuousClock.Instant, cut: WaitCut) async {
        let span = environment.log.begin(.take, "hand-over-begin")
        defer { span.end("hand-over") }
        let turn = Task { @MainActor in
            await monitorTurns.run {
                let released = monitors.values.map(\.writer)
                monitors = [:]
                for writer in released where writer.app != nil { writer.finishLater() }
                let devices = released.filter { $0.app == nil }
                let late = cut.isCut || ContinuousClock.now >= deadline
                let answers = late ? [:] : await boundedEach(devices, by: deadline, cut: cut) { await $0.finish() }
                for writer in devices where answers[ObjectIdentifier(writer)] == nil { writer.finishLater() }
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
