import DirigibleCore
import Foundation
import os

/// The running import of a studio (decision 0040). `Studio.Transport` holds it, so `Studio`
/// stores nothing for it. It is equal by the identity of its flags, so the transport stays
/// Hashable.
public struct ImportRun: Hashable, Sendable {
    /// The file name.
    public let name: String
    let flags: ImportFlags
    let task: Task<Result<ClipID, StudioError>, Never>

    public static func == (a: Self, b: Self) -> Bool { a.flags === b.flags }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(flags)) }
}

/// The cancel flag of an import, which its conversion thread reads, and the yield of a take in
/// another studio.
final class ImportFlags: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (cancelled: false, yielded: false))
    var isCancelled: Bool { state.withLock { $0.cancelled } }
    var isYielded: Bool { state.withLock { $0.yielded } }

    func cancel(yielding: Bool) {
        state.withLock { $0 = (true, $0.yielded || yielding) }
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
        try checkIdle()
        guard pendingTake == nil, !settling else { throw .busy }
        let stopped = endPlayForTake()
        let flags = ImportFlags()
        let task = Task { await importTurn(source, target, flags, stopped, progress) }
        transport = .importing(ImportRun(name: source.lastPathComponent, flags: flags, task: task))
        defer { transport = .idle }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            flags.cancel(yielding: false)
        }
        return try result.get()
    }

    /// Sets the cancel flag of the running import before its first await, then waits for its
    /// end. `settle()` calls it after it sets `settling`. With `yielding`, a take of another
    /// studio ends it (decision 0019), and `importAudio` throws `.importYielded`.
    func endImport(yielding: Bool = false) async {
        guard let run = importRun else { return }
        run.flags.cancel(yielding: yielding)
        _ = await run.task.value
    }

    /// One turn of the write chain: the Player stops, the conversion, the save, the undo entry,
    /// and the peaks of the new file. A flag that is set after the conversion writes nothing.
    private func importTurn(
        _ source: URL, _ target: ImportTarget, _ flags: ImportFlags, _ stopped: Int?,
        _ progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async -> Result<ClipID, StudioError> {
        await serialized { () async -> Result<ClipID, StudioError> in
            _ = await takePlayhead(stopped, nil)  // The Player stops.
            let before = session
            let converted = await convertImport(
                source, target, of: before, lock: lock, environment: environment, flags: flags,
                progress: { fraction in Task { @MainActor in progress(fraction) } })
            if flags.isCancelled {
                return .failure(
                    flags.isYielded ? .importYielded(file: source.lastPathComponent) : .audioImport(.cancelled))
            }
            let imported: (session: Session, clip: ClipID)
            switch converted {
            case .success(let value): imported = value
            case .failure(let error): return .failure(error)
            }
            switch await writeSession(
                imported.session, lock: lock, previous: url, recordings: recordings, environment.saveSession)
            {
            case .success(let package):
                url = package
                recordLevel(imported.session)
                poolChanged(from: before.files)
                return .success(imported.clip)
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
