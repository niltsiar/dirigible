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

extension Studio {
    /// Sync Clip to Track with Correct drift (decision 0077 D11): `driftRequest` in a blocking run of
    /// kind `.drift`, as a clip render (`blockingRun`). It saves `session.xml` and records one undo
    /// entry with `agent`, also for a move with a `DriftCause`. The errors of `Session.syncSpan`
    /// throw before the run. A read fault throws as for `syncClip`, a resample or rename fault
    /// `.clipRender`, a session refusal `.session`, and a cancel of the caller, of the banner, or by
    /// a take in another studio `.syncCancelled`. A throw changes nothing in memory, and the new
    /// WAVs go; after a failed save they stay as unused files.
    public func correctDrift(
        _ clip: ClipID, to track: TrackID, within: Frames? = nil, agent: AgentName? = nil,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws(StudioError) -> DriftSyncReport {
        try checkIdle()
        do throws(SessionError) { _ = try session.syncSpan(clip, to: track, within: within) } catch {
            throw .session(error)
        }
        let name = session.clip(clip).map { session.name(of: $0.clip) } ?? clip.rawValue
        let environment = environment
        return try await blockingRun(
            name: name, kind: .drift, cancelled: .syncCancelled, yielded: .syncCancelled, ripple: false, agent: agent
        ) { session, lock, flags in
            await correctDriftOffMain(
                clip, to: track, within: within, of: session, lock: lock, environment: environment, flags: flags,
                progress: { fraction in
                    Task { @MainActor [weak self] in
                        self?.importProgressed(flags, fraction)
                        progress(fraction)
                    }
                }
            ).map { ($0.session, $0.report, made: $0.made) }
        }
    }
}

/// `driftRequest` on a utility GCD thread, in the package that `lock` holds now, as `convertImport`
/// runs an import.
@concurrent nonisolated private func correctDriftOffMain(
    _ clip: ClipID, to track: TrackID, within: Frames?, of session: Session, lock: PackageLock,
    environment: CaptureEnvironment, flags: ImportFlags, progress: @escaping @Sendable (Double) -> Void
) async -> Result<(session: Session, report: DriftSyncReport, made: [URL]), StudioError> {
    @Sendable func run() -> Result<(session: Session, report: DriftSyncReport, made: [URL]), StudioError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let package: URL
        do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
        do throws(DriftFailure) {
            return .success(
                try driftRequest(
                    clip, to: track, within: within, of: session, in: package,
                    freeBytes: { environment.freeBytes(lock) }, progress: progress,
                    isCancelled: {
                        environment.importStep()
                        return flags.isCancelled
                    }))
        } catch {
            return .failure(StudioError(error))
        }
    }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: run()) }
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

    /// The error of a drift fix (decision 0077 D11): a cancel is the cancel of a sync.
    package init(_ failure: DriftFailure) {
        switch failure {
        case .read(let failure): self.init(failure)
        case .write(let error): self = .clipRender(error)
        case .session(let error): self = .session(error)
        case .cancelled: self = .syncCancelled
        }
    }
}
