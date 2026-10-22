import DirigibleCore
import Foundation

extension Studio {
    /// The duck of decision 0060: reads the speech runs of `speech` in `range` (nil: the whole
    /// session), cut by `Session.duckScope`, with `speechRuns`, and writes the duck of `music` with
    /// `Session.duck` (`range` nil: each whole clip). It runs as
    /// a level runs (`level`), on the `.ducking` transport, so the duck banner and its Cancel
    /// show; the read runs off the main actor; a change saves `session.xml` and records one undo
    /// entry with `agent` in the same turn. No runs throws `.session(.noSpeech)`. `cancelLevel()`
    /// or a cancel of the caller stops the read at its next second of audio; the flag is read last
    /// before the save, so a set flag throws `.duckCancelled` and saves nothing. A throw changes
    /// nothing.
    @discardableResult
    public func duck(
        speech: [TrackID], music: [TrackID], range: Range<Frames>?, shape: DuckShape, agent: AgentName? = nil,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws(StudioError) -> DuckResult {
        try checkIdle()
        let scope: Range<Frames>
        do throws(SessionError) { scope = try session.duckScope(range) } catch { throw .session(error) }
        let stopped = endPlayForTake()
        let flags = ImportFlags()
        (transport, levelFlags) = (.ducking, flags)
        defer { (transport, levelFlags) = (.idle, nil) }
        let hop: @Sendable (Double) -> Void = { fraction in Task { @MainActor in progress(fraction) } }
        let result = await withTaskCancellationHandler {
            await serialized { () async -> Result<DuckResult, StudioError> in
                _ = await takePlayhead(stopped, nil)  // The Player stops.
                await environment.beforeFinalize()
                let read: (runs: [Range<Frames>], unread: [FileID])
                switch await readSpeech(
                    speech, of: session, lock: lock, scope: scope, shape: shape, progress: hop,
                    isCancelled: { [step = environment.loudnessBlock] in
                        step()
                        return flags.isCancelled
                    })
                {
                case .success(let value): read = value
                case .failure(let error): return .failure(error)
                }
                if flags.isCancelled { return .failure(.duckCancelled) }
                var ducked = session
                let result: DuckResult
                do throws(SessionError) {
                    result = try ducked.duck(
                        runs: read.runs, unread: read.unread, shape: shape, music: music, scope: range)
                } catch {
                    return .failure(.session(error))
                }
                guard ducked != session else { return .success(result) }
                switch await writeSession(
                    ducked, lock: lock, previous: url, recordings: recordings, environment.saveSession)
                {
                case .success(let written):
                    url = written.package
                    backups = written.backups
                    recordLevel(ducked, agent: agent)
                    return .success(result)
                case .failure(let error):
                    return .failure(error)
                }
            }
        } onCancel: {
            flags.cancel(yielding: false)
        }
        return try result.get()
    }
}

/// `speechRuns` off the main actor, in the package that `lock` holds now.
@concurrent nonisolated func readSpeech(
    _ speech: [TrackID], of session: Session, lock: PackageLock, scope: Range<Frames>, shape: DuckShape,
    progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool
) async -> Result<(runs: [Range<Frames>], unread: [FileID]), StudioError> {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let package: URL
    do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
    do throws(POSIXError) {
        return .success(
            try speechRuns(
                of: speech, in: session, package: package, scope: scope, shape: shape, progress: progress,
                isCancelled: isCancelled))
    } catch {
        return .failure(error.code == .ECANCELED ? .duckCancelled : .duckRead(error.code.rawValue))
    }
}
