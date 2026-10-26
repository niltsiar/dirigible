import DirigibleCore
import Foundation

extension Studio {
    /// Splits the stereo clips `clips` with the pair writer `splitStereo` (decision 0053): two mono
    /// tracks under each source track, named with the suffixes `names`. It saves `session.xml` and
    /// records one undo entry with `agent`. It is a blocking run, as an import (`blockingRun`):
    /// `.busy` during a take, a pending take, an import, or `settle()`; a cancel of the calling task
    /// or of the banner throws `.split(.cancelled)`, and a take in another studio `.splitYielded`.
    /// Then the renamed WAVs go. A throw changes nothing in memory; after a failed save, the WAVs
    /// stay as unused files. Undo keeps them. `progress` and `importProgress` get the fraction on
    /// the main actor.
    public func splitStereo(
        _ clips: [ClipID], names: (left: String, right: String), agent: AgentName? = nil,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws(StudioError) -> [SplitPart] {
        let environment = environment
        return try await blockingRun(
            name: url.deletingPathExtension().lastPathComponent, kind: .split, cancelled: .split(.cancelled),
            yielded: .splitYielded, ripple: false, agent: agent
        ) { session, lock, flags in
            await splitOffMain(
                clips, names: names, of: session, lock: lock, environment: environment, flags: flags,
                progress: { fraction in
                    Task { @MainActor [weak self] in
                        self?.importProgressed(flags, fraction)
                        progress(fraction)
                    }
                })
        }
    }
}

/// `splitStereo` on a utility GCD thread, in the package that `lock` holds now, as `convertImport`
/// runs an import.
@concurrent nonisolated private func splitOffMain(
    _ clips: [ClipID], names: (left: String, right: String), of session: Session, lock: PackageLock,
    environment: CaptureEnvironment, flags: ImportFlags, progress: @escaping @Sendable (Double) -> Void
) async -> Result<(Session, [SplitPart], made: [URL]), StudioError> {
    @Sendable func run() -> Result<(Session, [SplitPart], made: [URL]), StudioError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let package: URL
        do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
        do throws(SplitError) {
            let split = try splitStereo(
                clips, names: names, of: session, in: package, freeBytes: { environment.freeBytes(lock) },
                progress: progress,
                isCancelled: {
                    environment.importStep()
                    return flags.isCancelled
                })
            return .success((split.session, split.parts, made: split.made))
        } catch {
            return .failure(.split(error))
        }
    }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: run()) }
    }
}
