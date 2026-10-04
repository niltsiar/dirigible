import AVFoundation
import DirigibleCore
import Foundation

/// The peak state of one pool file (decision 0017).
public enum PeakState: Hashable, Sendable {
    /// The view draws the clip box, with the live peaks of a take file (live take view), else
    /// with no waveform.
    case computing
    case ready(Peaks)
    /// `openMedia` gave a fault, or a read failed; `missingMedia` has the fault.
    case unavailable
}

/// The one stored peak value of a Studio, as `PlayState` is for playback.
struct PeakLoad {
    /// Nil for the command-line front end: no pass starts.
    let cache: URL?
    var states: [FileID: PeakState] = [:]
    var pass: Task<Void, Never>?
    /// `loadPeaks` during a pass: the pass runs once more.
    var again = false
}

extension Studio {
    /// Keyed by pool file. An edit that removes a file keeps its entry, so an undo finds it.
    public var peaks: [FileID: PeakState] { peakLoad.states }

    /// Starts a pass over the pool, or marks the running pass to run once more. It does nothing
    /// when the Studio has no cache folder or while `settle()` runs. The window calls it at
    /// focus, because a WAV can change outside the app.
    public func loadPeaks() {
        guard let cache = peakLoad.cache, !settling else { return }
        guard peakLoad.pass == nil else {
            peakLoad.again = true
            return
        }
        // The pass holds the Studio only for one file at a time, so a close drops it.
        peakLoad.pass = Task { [weak self] in
            var ids = self?.startPeakPass() ?? []
            files: while true {
                for id in ids {
                    guard let self, !peaksStopped() else { break files }
                    guard let file = session.files[id] else { continue }
                    let job = PeakJob(
                        file: file, lock: lock, rate: session.sampleRate, cache: cache,
                        known: peakLoad.states[id].flatMap(\.peaks)?.stamp, hook: environment.beforePeakBlock,
                        read: environment.peakRead)
                    let result = await loadFilePeaks(job) { [weak self] in await self?.peaksMayRun() ?? .stop }
                    guard apply(result, to: id) else { break files }
                }
                // The first file start of the next run checks the stop.
                guard let self, peakLoad.again else { break }
                ids = startPeakPass()
            }
            self?.peakLoad.pass = nil
        }
    }

    /// Studio calls it after an edit, an undo, a redo, and a finalize: a pass when the pool
    /// files changed.
    func poolChanged(from before: [FileID: AudioFile]) {
        if session.files != before { loadPeaks() }
    }

    /// `settle()` calls it last: cancels the pass and waits for its end, so no task holds the lock.
    func stopPeaks() async {
        guard let pass = peakLoad.pass else { return }
        pass.cancel()
        await pass.value
        peakLoad.again = false
    }

    /// The one stop check of the pass: at each file start and at each step of a wait.
    func peaksStopped() -> Bool { Task.isCancelled || settling }

    /// Before each block: `.stop` after a cancel or in settle; a wait in steps of 100 ms while
    /// a take starts, records, or finalizes, then `.waited`; else `.go`.
    func peaksMayRun() async -> PeakPause {
        var waited = false
        while !peaksStopped() {
            guard !isIdle else { return waited ? .waited : .go }
            waited = true
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .stop
    }

    /// The pool files in ID order. A file with no entry or `.unavailable` gets `.computing`.
    private func startPeakPass() -> [FileID] {
        peakLoad.again = false
        let ids = session.files.keys.sorted()
        for id in ids where peakLoad.states[id] == nil || peakLoad.states[id] == .unavailable {
            peakLoad.states[id] = .computing
        }
        return ids
    }

    /// False ends the pass with no state change.
    private func apply(_ result: PeakResult, to id: FileID) -> Bool {
        let fault: MediaFault?
        switch result {
        case .end: return false
        case .keep(let kept): fault = kept
        case .ready(let peaks, let kept):
            peakLoad.states[id] = .ready(peaks)
            fault = kept
        case .unavailable(let kept):
            peakLoad.states[id] = .unavailable
            fault = kept
        }
        if let fault { missingMedia[id] = fault }
        return true
    }
}

extension PeakState {
    var peaks: Peaks? {
        if case .ready(let peaks) = self { return peaks }
        return nil
    }
}

/// The values of one file of a pass, read on the main actor.
struct PeakJob: Sendable {
    let file: AudioFile
    let lock: PackageLock
    let rate: Int
    let cache: URL
    /// The stamp of the peaks in memory.
    let known: FileStamp?
    let hook: @Sendable (isolated (any Actor)?) async -> Void
    let read: @Sendable () -> Void
}

enum PeakResult: Sendable {
    /// The stamp is the one in memory.
    case keep(MediaFault?)
    case ready(Peaks, MediaFault?)
    case unavailable(MediaFault)
    /// A cancel, a package that left its volume, or no free descriptor.
    case end
}

/// One file of a pass, off the main actor: the package path that the lock holds now, the open
/// with its stamp, then the peaks in memory, the cache file, or a compute and a cache write. A
/// wait for a take opens the file again. A cache write error keeps the peaks in memory.
@concurrent nonisolated func loadFilePeaks(
    _ job: PeakJob, pause: @escaping @Sendable () async -> PeakPause
) async -> PeakResult {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let channels = job.file.layout.channelCount
    while true {
        job.read()
        guard let package = try? job.lock.package(),
            let opened = try? openMedia(job.file, in: package.appending(path: clipsFolderName), rate: job.rate)
        else { return .end }
        guard let audio = opened.file, let stamp = opened.stamp else {
            return .unavailable(opened.fault ?? .unreadable)
        }
        if stamp == job.known { return .keep(opened.fault) }
        let path = job.file.path
        if let peaks = PeakFile.read(path: path, stamp: stamp, channels: channels, rate: job.rate, in: job.cache) {
            PeakFile.touch(path: path, stamp: stamp, in: job.cache)
            return .ready(peaks, opened.fault)
        }
        do {
            let peaks = try await computePeaks(audio, stamp: stamp, afterRead: job.read) {
                let next = await pause()
                if next == .go { await job.hook(#isolation) }
                return next
            }
            try? PeakFile.write(peaks, path: path, in: job.cache)
            return .ready(peaks, opened.fault)
        } catch .restart {
            continue
        } catch .cancelled {
            return .end
        } catch {
            return .unavailable(.unreadable)
        }
    }
}
