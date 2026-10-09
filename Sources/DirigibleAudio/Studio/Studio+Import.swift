import DirigibleCore
import Foundation
import os

/// The running import of a studio (decision 0040). `Studio.Transport` holds it, so `Studio`
/// stores nothing for it. It is equal by the identity of its flags, so the transport stays
/// Hashable.
public struct ImportRun: Hashable, Sendable {
    /// What the run converts or copies: a file (decision 0040) or the clips of a paste from
    /// another package (decision 0042).
    public enum Kind: Hashable, Sendable { case file, paste }

    /// The file name, or the name of the source package of a paste.
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

    /// Sets the flag. True only for the call that sets it first.
    @discardableResult
    func cancel(yielding: Bool) -> Bool {
        state.withLock { state in
            defer { state = (true, state.yielded || yielding) }
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
    /// within one block: then it throws `.audioImport(.cancelled)`, or `.importYielded` for the
    /// take. A throw changes nothing in memory; after the rename, the WAV stays as an unused file.
    /// The transport is `.idle` after every exit.
    public func importAudio(
        _ source: URL, to target: ImportTarget, progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws(StudioError) -> ClipID {
        let environment = environment
        return try await blockingRun(
            name: source.lastPathComponent, kind: .file, cancelled: .audioImport(.cancelled),
            yielded: .importYielded(file: source.lastPathComponent)
        ) { session, lock, flags in
            await convertImport(
                source, target, of: session, lock: lock, environment: environment, flags: flags,
                progress: { fraction in Task { @MainActor in progress(fraction) } }
            ).map { ($0.session, $0.clip) }
        }
    }

    /// The blocking run of an import or a paste from another package (decisions 0040 and 0042):
    /// `checkIdle`, `.busy` during a pending take and during `settle()`, the stop of play, the
    /// transport `.importing`, and `work` in one turn of the write chain. A cancel of the calling
    /// task sets the flag. `work` gets the session of its turn, the lock, and the flags; after it,
    /// a set flag writes nothing and throws `cancelled`, or `yielded` for a take in another
    /// studio. Else the run saves, records one undo entry, and loads the peaks of new files.
    func blockingRun<Value: Sendable>(
        name: String, kind: ImportRun.Kind, cancelled: StudioError, yielded: StudioError,
        work: @escaping @Sendable (Session, PackageLock, ImportFlags) async -> Result<(Session, Value), StudioError>
    ) async throws(StudioError) -> Value {
        try checkIdle()
        guard pendingTake == nil, !settling else { throw .busy }
        let stopped = endPlayForTake()
        let flags = ImportFlags()
        let task = Task { await blockingTurn(flags, stopped, cancelled: cancelled, yielded: yielded, work: work) }
        transport = .importing(ImportRun(name: name, kind: kind, flags: flags))
        defer { transport = .idle }
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
    /// for the import turn in the write chain. With `yielding`, a take of another studio ends it
    /// (decision 0019), and `importAudio` throws `.importYielded`. True only for the call that
    /// sets the flag first.
    @discardableResult
    func endImport(yielding: Bool = false) -> Bool {
        importRun?.flags.cancel(yielding: yielding) ?? false
    }

    /// One turn of the write chain: the Player stops, the work, the save, the undo entry, and the
    /// peaks of the new files. A flag that is set after the work writes nothing.
    private func blockingTurn<Value: Sendable>(
        _ flags: ImportFlags, _ stopped: Int?, cancelled: StudioError, yielded: StudioError,
        work: @Sendable (Session, PackageLock, ImportFlags) async -> Result<(Session, Value), StudioError>
    ) async -> Result<Value, StudioError> {
        await serialized { () async -> Result<Value, StudioError> in
            _ = await takePlayhead(stopped, nil)  // The Player stops.
            let before = session
            let done = await work(before, lock, flags)
            if flags.isCancelled { return .failure(flags.isYielded ? yielded : cancelled) }
            let (edited, value): (Session, Value)
            switch done {
            case .success(let result): (edited, value) = result
            case .failure(let error): return .failure(error)
            }
            switch await writeSession(
                edited, lock: lock, previous: url, recordings: recordings, environment.saveSession)
            {
            case .success(let written):
                url = written.package
                backups = written.backups
                recordLevel(edited)
                poolChanged(from: before.files)
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
    _ source: URL, _ target: ImportTarget, of session: Session, lock: PackageLock, environment: CaptureEnvironment,
    flags: ImportFlags, progress: @escaping @Sendable (Double) -> Void
) async -> Result<(session: Session, clip: ClipID), StudioError> {
    @Sendable func run() -> Result<(session: Session, clip: ClipID), StudioError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let package: URL
        do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
        do throws(ImportError) {
            return .success(
                try importAudio(
                    source, to: target, of: session, in: package, freeBytes: { environment.freeBytes(lock) },
                    progress: progress,
                    isCancelled: {
                        environment.importStep()
                        return flags.isCancelled
                    }))
        } catch {
            return .failure(.audioImport(error))
        }
    }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: run()) }
    }
}
