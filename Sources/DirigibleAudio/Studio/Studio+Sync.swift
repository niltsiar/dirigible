import DirigibleCore
import Foundation

extension Studio {
    /// Sync Clip to Track (decision 0076, **Job**): reads the lag of `clip` on `track` with
    /// `syncLag` through `runReadJob` on `.syncing`, then moves the clip by it with `Session.sync`
    /// as one undo entry with `agent`. `within` nil is the default span, clamped to the cap. It
    /// returns the result of the read and the cut of the move. The errors of
    /// `Session.syncSpan` throw before a read; no match throws `.syncNoMatch`, a missing or
    /// unreadable file `.syncFile`, a read errno `.syncRead`, and a cancel `.syncCancelled`. Each
    /// throw changes nothing.
    @discardableResult
    public func syncClip(
        _ clip: ClipID, to track: TrackID, within: Frames? = nil, agent: AgentName? = nil,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws(StudioError) -> (SyncResult, cut: SyncCut) {
        try checkIdle()
        let span: Range<Frames>
        do throws(SessionError) { span = try session.syncSpan(clip, to: track, within: within) } catch {
            throw .session(error)
        }
        return try await runReadJob(
            .syncing, cancelled: .syncCancelled, agent: agent, progress: progress,
            read: { session, lock, progress, isCancelled in
                await readSync(
                    clip, to: track, span: span, of: session, lock: lock, progress: progress, isCancelled: isCancelled)
            },
            apply: { session, result throws(StudioError) in
                var moved = session
                do throws(SessionError) {
                    let cut = try moved.sync(clip, by: result.lag)
                    return (moved, (result, cut: cut))
                } catch {
                    throw .session(error)
                }
            })
    }
}

/// `syncLag` off the main actor, in the package that `lock` holds now.
@concurrent nonisolated func readSync(
    _ clip: ClipID, to track: TrackID, span: Range<Frames>, of session: Session, lock: PackageLock,
    progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool
) async -> Result<SyncResult, StudioError> {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let package: URL
    do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
    do throws(SyncFailure) {
        return .success(
            try syncLag(
                of: clip, to: track, in: session, package: package, span: span, progress: progress,
                isCancelled: isCancelled))
    } catch {
        return .failure(StudioError(error))
    }
}

extension StudioError {
    /// The error of a sync read that gave no lag.
    package init(_ failure: SyncFailure) {
        switch failure {
        case .noMatch(let best): self = .syncNoMatch(best: best)
        case .file(let file, let fault): self = .syncFile(file, fault)
        case .cancelled: self = .syncCancelled
        case .read(let error): self = .syncRead(error.code.rawValue)
        }
    }
}
