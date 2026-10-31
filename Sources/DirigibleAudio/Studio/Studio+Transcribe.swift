import DirigibleCore
import Foundation

/// A mono file of a split stereo that committed during a transcription job, its source file, and
/// the span of the source that it holds (decision 0065 D4).
typealias Derivation = (source: FileID, derived: FileID, span: Range<Frames>)

/// The running transcription job of a studio: its read run, and the mono files of each split stereo
/// that committed while it runs, in commit order (decision 0065 D5).
struct TranscribeRun {
    let run: ReadRun
    var splits: [Derivation] = []
}

/// The end of a transcription job (decision 0065 D5).
public struct TranscribeReport: Hashable, Sendable {
    /// Nil when the job kept no word: then the session did not change.
    public let id: TranscriptID?
    public let kept: Int
    /// The words of a file that is not in the pool.
    public let skipped: Int
    /// The words with no length, or with no frame in their span (`SpanMap`).
    public let untimed: Int
    /// The transcripts that did not load, which the new transcript removed (decision 0055).
    public let dropped: [String]
    /// The language code of the engine, for example "es".
    public let language: String
}

/// The stage of a transcription job and its fraction from 0 to 1.
public enum TranscribeProgress: Hashable, Sendable {
    /// The model download: the received bytes over the catalog byte count.
    case download(Double)
    /// The engine: the pieces done over the piece count.
    case transcribe(Double)
}

extension Studio {
    /// Transcribes the clips of track `id` with `model` (decision 0065 D5) and adds the words as the
    /// transcript `name`, else of the track name, in one undo entry with `agent`. It downloads the model first
    /// when the model folder does not have it. The job runs beside the write chain: edits go on, and
    /// the words anchor to the files, so an edit during the job keeps its place. It throws `.busy`
    /// during a take, a pending take, a take start, a level, a duck, an import, or `settle()`, while
    /// a job runs in any studio, and while another studio records, has a pending take, or starts a
    /// take. A take start in any studio throws `.transcriptionYielded`; the banner Cancel
    /// (`cancelTranscription()`), a cancel of the caller, and `settle()` throw
    /// `.transcriptionCancelled`. Then the job writes nothing. A job that keeps no word changes
    /// nothing and gives no ID. It returns after the save of the new session. `progress` gets the
    /// stage and the fraction on the main actor.
    public func transcribe(
        track id: TrackID, language: WhisperLanguage, model: WhisperModel, name: String? = nil,
        agent: AgentName? = nil,
        progress: @escaping @MainActor @Sendable (TranscribeProgress) -> Void = { _ in }
    ) async throws(StudioError) -> TranscribeReport {
        try checkIdle()
        let others = otherStudios()
        guard session.recording == nil, transcribing == nil,
            !others.contains(where: { $0.transcribing != nil || $0.session.recording != nil || $0.isStarting })
        else { throw .busy }
        guard let track = session.track(id) else { throw .session(.unknownTrack(id)) }
        // The start turn: no `await` from the refusals to the join of `readRuns`, so the `exportEnd()`
        // of each later take start sees the job.
        let (map, snapshot, environment, lock, run) =
            (SpanMap(clips: track.clips, sampleRate: session.sampleRate), session, environment, lock, ReadRun())
        readRuns.append(run)
        transcribing = TranscribeRun(run: run)
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: environment.transcribeReason)
        defer {
            leaveTranscription(run)
            ProcessInfo.processInfo.endActivity(activity)
        }
        let hop: @Sendable (TranscribeProgress) -> Void = { stage in Task { @MainActor in progress(stage) } }
        let work = await withTaskCancellationHandler {
            await transcribeWork(
                map, session: snapshot, lock: lock, language: language, model: model, environment: environment,
                run: run, progress: hop)
        } onCancel: {
            run.cancel()
        }
        await environment.transcribeWorkDone()
        // The end turn. A set flag decides the exit, also after an engine error.
        while true {
            if run.cancelled.withLock({ $0 }) {
                throw run.end.withLock { $0 } == .take ? .transcriptionYielded : .transcriptionCancelled
            }
            let words: TranscribedWords
            switch work {
            case .success(let done?): words = done
            // No flag and no words: the engine part saw a flag that the end turn reads above.
            case .success(nil): throw .transcriptionCancelled
            case .failure(let error): throw error
            }
            if isIdle, !settling {
                // No `await` from the flag read to the edit, so the whole change comes before the save.
                let derived = transcribing?.splits ?? []
                let added: (id: TranscriptID?, kept: Int, skipped: Int, dropped: [String])
                do throws(SessionError) {
                    added = try recordEdit(agent: agent) { (session: inout Session) throws(SessionError) in
                        try session.addTranscript(words.words, name: name ?? track.name, derived: derived)
                    }
                } catch {
                    throw .session(error)
                }
                leaveTranscription(run)
                await serialized {}
                return TranscribeReport(
                    id: added.id, kept: added.kept, skipped: added.skipped, untimed: words.untimed,
                    dropped: added.dropped, language: words.language)
            }
            // A level, a duck, an import, a paste, a split, a render, a placement, or a take start of
            // this studio runs. The sleep is in a task of its own, so a cancel of the caller does not
            // make the wait spin; `serialized {}` returns with no suspension after a `blockingRun`
            // turn, so the main actor would spin.
            await Task { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
    }

    /// The Cancel of the Transcribe banner: sets the flags of the running job, with no wait. The job
    /// ends at its next stop check, throws `.transcriptionCancelled`, and writes nothing.
    public func cancelTranscription() { transcribing?.run.cancel() }

    /// Takes the job of `run` out of `transcribing` and `readRuns`.
    private func leaveTranscription(_ run: ReadRun) {
        if transcribing?.run === run { transcribing = nil }
        endRead(run)
    }
}
