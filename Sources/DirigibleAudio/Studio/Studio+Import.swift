import DirigibleCore
import Foundation
import os

/// The running import of a studio (decision 0040). `Studio.Transport` holds it, so `Studio`
/// stores nothing for it. It is equal by the identity of its flags, so the transport stays
/// Hashable.
public struct ImportRun: Hashable, Sendable {
    /// What the run converts or copies: a file (decision 0040), the clips of a paste from another
    /// package (decision 0042), the stereo clips of a split (decision 0053), the clips of a clip
    /// render (decision 0054), a clip of a drift fix (decision 0077), the tracks of another
    /// session package (decision 0075), or the clips of an add to Favorites (decision 0081).
    public enum Kind: Hashable, Sendable { case file, paste, split, clipRender, drift, session, favorite }

    /// The file name, the name of the source package of a paste or a session import, the name of
    /// the package of a split or a clip render, or the name of the clip of a drift fix.
    public let name: String
    public let kind: Kind
    let flags: ImportFlags

    public static func == (a: Self, b: Self) -> Bool { a.flags === b.flags }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(flags)) }
}

/// The cancel flag of an import, which its conversion thread reads, and the yield of a take in
/// another studio.
final class ImportFlags: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (cancelled: false, yielded: false))
    var isCancelled: Bool { state.withLock { $0.cancelled } }
    var isYielded: Bool { state.withLock { $0.yielded } }

    /// Sets the flag. True only for the call that sets it first; only that call sets the yield, so
    /// the first stop names the cause.
    @discardableResult
    func cancel(yielding: Bool) -> Bool {
        state.withLock { state in
            defer { state = (true, state.cancelled ? state.yielded : yielding) }
            return !state.cancelled
        }
    }
}

extension Studio {
    /// The running import, or nil.
    var importRun: ImportRun? {
        if case .importing(let run) = transport { run } else { nil }
    }

    /// Imports `source` with `importAudio` (decision 0040), levels the clip, saves `session.xml`,
    /// and records one undo entry. A running play stops first, as at a take start. The conversion
    /// runs on a utility GCD thread; meanwhile every other entry point throws `.busy`. It throws
    /// `.busy` during a pending take and during `settle()`. `progress` gets the fraction on the
    /// main actor. A cancel of the calling task, `settle()`, or a take in another studio ends it
    /// within one block, also in the level step: then it throws `.audioImport(.cancelled)`, or
    /// `.importYielded` for the take, and the renamed WAV goes (decision 0049). A throw changes
    /// nothing in memory; after a failed save, the WAV stays as an unused file. The transport is
    /// `.idle` after every exit. With no `level`, the clip keeps the gain of the conversion.
    /// `agent` names the agent of an MCP import in its undo entry. `importProgress` also gets the
    /// fraction, for the banner of an agent import.
    public func importAudio(
        _ source: URL, to target: ImportTarget, level: Bool = true, agent: AgentName? = nil,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws(StudioError) -> ClipID {
        let environment = environment
        return try await blockingRun(
            name: source.lastPathComponent, kind: .file, cancelled: .audioImport(.cancelled),
            yielded: .importYielded(file: source.lastPathComponent), ripple: false, agent: agent
        ) { session, lock, flags in
            let done = await convertImport(
                source, target, of: session, lock: lock, level: level, environment: environment, flags: flags,
                progress: { fraction in
                    Task { @MainActor [weak self] in
                        self?.importProgressed(flags, fraction)
                        progress(fraction)
                    }
                })
            await environment.importWorkDone()
            return done.map { ($0.session, $0.clip, made: [$0.made].compactMap { $0 }) }
        }
    }

    /// A progress hop of the import run of `flags`. Hops can arrive out of order, so it keeps the
    /// largest fraction of the run; a hop of an older run changes nothing.
    func importProgressed(_ flags: ImportFlags, _ fraction: Double) {
        guard importRun?.flags === flags else { return }
        importProgress = max(importProgress, fraction)
    }

    /// The Cancel of the banner of an import that the window did not start: an agent import
    /// (decision 0049). The import ends at its next block, and the renamed WAV goes.
    public func cancelImport() { endImport(.user) }

    /// The blocking run of an import, a paste from another package, a split, or a clip render
    /// (decisions 0040, 0042, 0053, and 0054):
    /// `checkIdle`, `.rippleBlocked` for a `ripple` under a pending or split take (decision 0037),
    /// `.busy` during a pending take and during `settle()`, the stop of play, the
    /// transport `.importing`, and `work` in one turn of the write chain. A cancel of the calling
    /// task sets the flag. `work` gets the session of its turn, the lock, and the flags, and gives
    /// the files that it made; after it, a set flag removes them with `removeMadeFiles`, writes
    /// nothing, and throws `cancelled`, or `yielded` for a take in another studio (decision 0049).
    /// Else the run saves, records one undo entry with `agent`, and loads the peaks of new files,
    /// unless `work` gives the session of its turn back: then it saves nothing, records nothing, and
    /// removes the made files.
    /// `importProgress` starts at 0 for each run. From the end of the refusals to its end, the run
    /// holds a user-initiated activity that stops idle sleep and App Nap (decision 0040).
    func blockingRun<Value: Sendable>(
        name: String, kind: ImportRun.Kind, cancelled: StudioError, yielded: StudioError, ripple: Bool,
        agent: AgentName? = nil,
        work:
            @escaping @Sendable (Session, PackageLock, ImportFlags) async -> Result<
                (Session, Value, made: [URL]), StudioError
            >
    ) async throws(StudioError) -> Value {
        try checkIdle()
        if ripple { try checkRipple() }
        guard pendingTake == nil, !settling else { throw .busy }
        let stopped = endPlayForTake()
        let flags = ImportFlags()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: environment.blockingRunReason)
        let undoName: History.Name? = kind == .session ? .importSession : nil
        let task = Task {
            await blockingTurn(
                flags, stopped, cancelled: cancelled, yielded: yielded, agent: agent, undoName: undoName, work: work)
        }
        (importProgress, importStop) = (0, nil)
        transport = .importing(ImportRun(name: name, kind: kind, flags: flags))
        defer {
            transport = .idle
            ProcessInfo.processInfo.endActivity(activity)
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            flags.cancel(yielding: false)
        }
        return try result.get()
    }

    /// Sets the cancel flag of the running import, with no wait: a source read can stall (an
    /// online-only file), and a take never waits for it (code gate 1). The import ends at its
    /// next block and writes nothing. `settle()` calls it before its first await, and then waits
    /// for the import turn in the write chain. With `.take`, a take of another studio ends it
    /// (decision 0019), and `importAudio` throws `.importYielded`. The call that sets the flag
    /// first sets `importStop` and gives true.
    @discardableResult
    func endImport(_ stop: ExportStop) -> Bool {
        guard importRun?.flags.cancel(yielding: stop == .take) == true else { return false }
        importStop = stop
        return true
    }

    /// One turn of the write chain: the Player stops, the work, the save, the undo entry, and the
    /// peaks of the new files. A flag that is set after the work removes the made files and writes
    /// nothing. A work session equal to the session of the turn gets no save and no undo entry, and
    /// its made files go.
    private func blockingTurn<Value: Sendable>(
        _ flags: ImportFlags, _ stopped: Int?, cancelled: StudioError, yielded: StudioError, agent: AgentName?,
        undoName: History.Name?,
        work: @Sendable (Session, PackageLock, ImportFlags) async -> Result<(Session, Value, made: [URL]), StudioError>
    ) async -> Result<Value, StudioError> {
        await serialized { () async -> Result<Value, StudioError> in
            _ = await takePlayhead(stopped, nil)  // The Player stops.
            let before = session
            let done = await work(before, lock, flags)
            if flags.isCancelled {
                if case .success(let result) = done { await removeMadeFilesOffMain(result.made) }
                return .failure(flags.isYielded ? yielded : cancelled)
            }
            let (edited, value, made): (Session, Value, [URL])
            switch done {
            case .success(let result): (edited, value, made) = result
            case .failure(let error): return .failure(error)
            }
            if edited == before {
                await removeMadeFilesOffMain(made)
                return .success(value)
            }
            switch await writeSession(
                edited, lock: lock, previous: url, recordings: recordings, environment.saveSession)
            {
            case .success(let written):
                url = written.package
                backups = written.backups
                recordLevel(edited, agent: agent, name: undoName)
                poolChanged(from: before.files, agent: agent)
                return .success(value)
            case .failure(let error):
                return .failure(error)
            }
        }
    }
}

/// `importAudio` on a utility GCD thread, in the package that `lock` holds now. A Swift task that
/// a caller awaits takes the priority of that caller, so the block loop does not run in one.
@concurrent nonisolated func convertImport(
    _ source: URL, _ target: ImportTarget, of session: Session, lock: PackageLock, level: Bool,
    environment: CaptureEnvironment, flags: ImportFlags, progress: @escaping @Sendable (Double) -> Void
) async -> Result<(session: Session, clip: ClipID, made: URL?), StudioError> {
    @Sendable func run() -> Result<(session: Session, clip: ClipID, made: URL?), StudioError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let package: URL
        do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
        do throws(ImportError) {
            let imported = try importAudio(
                source, to: target, of: session, in: package, level: level,
                freeBytes: { environment.freeBytes(lock) }, progress: progress,
                isCancelled: {
                    environment.importStep()
                    return flags.isCancelled
                })
            return .success(imported)
        } catch {
            return .failure(.audioImport(error))
        }
    }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: run()) }
    }
}
