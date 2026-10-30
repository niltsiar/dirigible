import DirigibleCore
import Foundation

/// The end of a clip render: each moved clip with its new file, the treatment of the request, and
/// each clip that needed no render (decision 0057). `repairs` holds the de-clip result of each
/// clip of a run with a de-clip (decision 0064).
public struct ClipRenderReport: Sendable {
    public let clips: [RenderedClip]
    public let treatment: Treatment
    public let unchanged: [ClipID]
    package let repairs: [ClipID: ClipRepair]
}

extension Studio {
    /// Renders the clips `clips` for `request` with `renderRequest` (decisions 0054 and 0057): new
    /// WAVs in `Clips/`, and the clips move onto them. It saves `session.xml` and records one undo
    /// entry with `agent`. It is a blocking run, as a split (`blockingRun`): the Player stops, and
    /// `.busy` during a take, a pending take, an import, a paste or split run, or `settle()`. A
    /// request that needs no render on the session of its turn gives each clip in `unchanged`, with
    /// no save and no undo entry. A cancel of the calling task or of the
    /// banner throws `.clipRender(.cancelled)`, and a take in another studio `.clipRenderYielded`.
    /// Then the renamed WAVs go. A throw changes nothing in memory; after a failed save, the WAVs
    /// stay as unused files. Undo keeps them. `progress` and `importProgress` get the fraction on
    /// the main actor.
    public func renderClips(
        _ clips: [ClipID], request: ClipRenderRequest, agent: AgentName? = nil,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws(StudioError) -> ClipRenderReport {
        let environment = environment
        let rendered = try await blockingRun(
            name: url.deletingPathExtension().lastPathComponent, kind: .clipRender,
            cancelled: .clipRender(.cancelled), yielded: .clipRenderYielded, ripple: false, agent: agent
        ) { session, lock, flags in
            let done = await renderOffMain(
                clips, request: request, of: session, lock: lock, environment: environment, flags: flags,
                progress: { fraction in
                    Task { @MainActor [weak self] in
                        self?.importProgressed(flags, fraction)
                        progress(fraction)
                    }
                })
            await environment.clipRenderWorkDone()
            return done.map {
                ($0.session, (clips: $0.clips, unchanged: $0.unchanged, repairs: $0.repairs), made: $0.made)
            }
        }
        return ClipRenderReport(
            clips: rendered.clips, treatment: request.treatment, unchanged: rendered.unchanged,
            repairs: rendered.repairs)
    }
}

/// `renderRequest` on a utility GCD thread, in the package that `lock` holds now, as `convertImport`
/// runs an import.
@concurrent nonisolated private func renderOffMain(
    _ clips: [ClipID], request: ClipRenderRequest, of session: Session, lock: PackageLock,
    environment: CaptureEnvironment, flags: ImportFlags, progress: @escaping @Sendable (Double) -> Void
) async -> Result<ClipRenderOutcome, StudioError> {
    @Sendable func run() -> Result<ClipRenderOutcome, StudioError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let package: URL
        do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
        do throws(ClipRenderError) {
            return .success(
                try renderRequest(
                    clips, request: request, of: session, in: package, freeBytes: { environment.freeBytes(lock) },
                    readFault: environment.clipRenderRead, progress: progress,
                    isCancelled: {
                        environment.importStep()
                        return flags.isCancelled
                    }))
        } catch {
            return .failure(.clipRender(error))
        }
    }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: run()) }
    }
}
