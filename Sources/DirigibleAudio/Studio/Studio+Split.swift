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
    /// the main actor. A split that commits during a transcription job adds the source file, the
    /// mono file, and the span of each mono file to the job (decision 0065 D5).
    public func splitStereo(
        _ clips: [ClipID], names: (left: String, right: String), agent: AgentName? = nil,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws(StudioError) -> [SplitPart] {
        let environment = environment
        let (parts, derived) = try await blockingRun(
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
        transcribing?.splits += derived
        return parts
    }
}

/// The mono files of `parts`, each with its source file and the span of the source that it holds:
/// a mono clip has the offset of its source clip minus the span start, and the length of the span
/// (decision 0053).
private func derivations(of parts: [SplitPart], before: Session, after: Session) -> [Derivation] {
    var derived: [Derivation] = []
    for part in parts {
        guard let source = before.clip(part.source)?.clip else { continue }
        for id in [part.left, part.right] {
            guard let mono = after.clip(id)?.clip, let file = after.files[mono.file],
                !derived.contains(where: { $0.derived == mono.file })
            else { continue }
            let start = source.offset - mono.offset
            derived.append((source.file, mono.file, start..<(start + file.length)))
        }
    }
    return derived
}

/// `splitStereo` on a utility GCD thread, in the package that `lock` holds now, as `convertImport`
/// runs an import.
@concurrent nonisolated private func splitOffMain(
    _ clips: [ClipID], names: (left: String, right: String), of session: Session, lock: PackageLock,
    environment: CaptureEnvironment, flags: ImportFlags, progress: @escaping @Sendable (Double) -> Void
) async -> Result<(Session, ([SplitPart], [Derivation]), made: [URL]), StudioError> {
    @Sendable func run() -> Result<(Session, ([SplitPart], [Derivation]), made: [URL]), StudioError> {
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
            let derived = derivations(of: split.parts, before: session, after: split.session)
            return .success((split.session, (split.parts, derived), made: split.made))
        } catch {
            return .failure(.split(error))
        }
    }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: run()) }
    }
}
