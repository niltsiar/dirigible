import DirigibleCore
import Foundation

extension Studio {
    /// The duck of decision 0060: checks the lists with `Session.checkDuckLists`, reads the speech
    /// runs of `speech` in `range` (nil: the whole session), cut by `Session.duckScope`, with
    /// `speechRuns`, and writes the duck of `music` with `Session.duck` (`range` nil: each whole
    /// clip). It runs through `runReadJob` on the `.ducking` transport, so the duck banner and its
    /// Cancel show. No runs throws `.session(.noSpeech)`. A cancel throws `.duckCancelled`.
    @discardableResult
    public func duck(
        speech: [TrackID], music: [TrackID], range: Range<Frames>?, shape: DuckShape, agent: AgentName? = nil,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws(StudioError) -> DuckResult {
        try checkIdle()
        let scope: Range<Frames>
        do throws(SessionError) {
            try session.checkDuckLists(speech: speech, music: music)
            scope = try session.duckScope(range)
        } catch {
            throw .session(error)
        }
        return try await runReadJob(
            .ducking, cancelled: .duckCancelled, agent: agent, progress: progress,
            read: { session, lock, progress, isCancelled in
                await readSpeech(
                    speech, of: session, lock: lock, scope: scope, shape: shape, progress: progress,
                    isCancelled: isCancelled)
            },
            apply: { session, read throws(StudioError) in
                var ducked = session
                do throws(SessionError) {
                    let result = try ducked.duck(
                        runs: read.runs, unread: read.unread, shape: shape, music: music, scope: range)
                    return (ducked, result)
                } catch {
                    throw .session(error)
                }
            })
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
