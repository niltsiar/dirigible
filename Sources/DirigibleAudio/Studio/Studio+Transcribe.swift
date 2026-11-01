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
    /// The record of the check of a model file of the user; nil for a catalog model.
    public let modelFile: PassedModelFile?
}

/// The stage of a transcription job and its fraction from 0 to 1.
public enum TranscribeProgress: Hashable, Sendable {
    /// The model download: the received bytes over the catalog byte count.
    case download(Double)
    /// The check of a model file of the user (decision 0065, D8).
    case check
    /// The check of the model file passed with this record, before the engine starts. A job sends
    /// it also when it ends after the check with an error or a stop.
    case checked(PassedModelFile)
    /// The engine: the values of `PieceProgress`.
    case transcribe(Double)
}

extension Studio {
    /// Transcribes the clips of track `id` with `model` (decision 0065 D5) and adds the words as the
    /// transcript `name`, else of the track name, in one undo entry with `agent`. For a catalog model,
    /// it downloads the model first when the model folder does not have it; for a model file of the
    /// user, it checks the file first (D8). The job runs beside the write chain: edits go on, and
    /// the words anchor to the files, so an edit during the job keeps its place. It throws `.busy`
    /// during a take, a pending take, a take start, a level, a duck, an import, or `settle()`, while
    /// a job runs in any studio, and while another studio records, has a pending take, or starts a
    /// take. A take start in any studio throws `.transcriptionYielded`; the banner Cancel
    /// (`cancelTranscription()`), a cancel of the caller, and `settle()` throw
    /// `.transcriptionCancelled`. Then the job writes nothing. A job that keeps no word changes
    /// nothing and gives no ID. It returns after the save of the new session. `progress` gets the
    /// stage and the fraction on the main actor.
    public func transcribe(
        track id: TrackID, language: WhisperLanguage, model: WhisperModelChoice, name: String? = nil,
        agent: AgentName? = nil, download: DownloadActivity = DownloadActivity(),
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
            (SpanMap(clips: track.clips, session: session), session, environment, lock, ReadRun())
        readRuns.append(run)
        transcribing = TranscribeRun(run: run)
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: environment.transcribeReason)
        defer {
            leaveTranscription(run)
            ProcessInfo.processInfo.endActivity(activity)
        }
        let hop: @Sendable (TranscribeProgress) -> Void = { stage in Task { @MainActor in progress(stage) } }
        // `.check` and `.checked` arrive in order and before the job ends, so a caller keeps a passed
        // check whatever the end of the job.
        let announce: @Sendable (TranscribeProgress) async -> Void = { stage in
            await MainActor.run { progress(stage) }
        }
        // The work, the step after it, and the wait for idle up to the edit: a cancel of the caller
        // in any of them sets the flags that the end turn reads.
        func job() async throws(StudioError) -> TranscribeReport {
            let work = await transcribeWork(
                map, session: snapshot, lock: lock, language: language, model: model, environment: environment,
                run: run, download: download, announce: announce, progress: hop)
            await environment.transcribeWorkDone()
            // The end turn. A set flag decides the exit, also after an engine error.
            while true {
                if run.cancelled.withLock({ $0 }) {
                    throw run.end.withLock { $0 } == .take ? .transcriptionYielded : .transcriptionCancelled
                }
                let (words, modelFile): (TranscribedWords, PassedModelFile?)
                switch work {
                case .success(let done?): (words, modelFile) = done
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
                        dropped: added.dropped, language: words.language, modelFile: modelFile)
                }
                // A level, a duck, an import, a paste, a split, a render, a placement, or a take start of
                // this studio runs. The sleep is in a task of its own, so a cancel of the caller does not
                // make the wait spin; `serialized {}` returns with no suspension after a `blockingRun`
                // turn, so the main actor would spin.
                await Task { try? await Task.sleep(for: .milliseconds(10)) }.value
            }
        }
        let outcome = await withTaskCancellationHandler { () async -> Result<TranscribeReport, StudioError> in
            do throws(StudioError) { return .success(try await job()) } catch { return .failure(error) }
        } onCancel: {
            run.cancel()
        }
        return try outcome.get()
    }

    /// The check of a model file of the user for the Transcribe sheet (decision 0065, D8): a read
    /// run of this studio, so a take start in any studio throws `.readYielded`, `settle()` throws
    /// `.readClosed`, and a cancel of the caller throws `.transcriptionCancelled`. Each of them
    /// ends the helper. It is no job: a job in another studio does not refuse it. It throws the
    /// refusal of `checkModelFileIdle()` before any hash.
    public func checkModelFile(_ url: URL, passed: PassedModelFile?) async throws(StudioError) -> CheckedModel {
        try await modelFileRead { environment, stopped throws(ModelFileCheckError) in
            try environment.checkModelFile(url, passed, stopped)
        }
    }

    /// The SHA-256 of a kept model file at the sheet open (C24), as a read run of
    /// `checkModelFile`: each stop ends it at the next 1 MiB chunk.
    public func hashModelFile(_ url: URL) async throws(StudioError) -> String {
        try await modelFileRead { environment, stopped throws(ModelFileCheckError) in
            try environment.hashModelFile(url, stopped)
        }
    }

    /// `body` on the job thread as a read run of this studio, with the stop check of the run.
    private func modelFileRead<T: Sendable>(
        _ body:
            @escaping @Sendable (CaptureEnvironment, @escaping @Sendable () -> Bool) throws(ModelFileCheckError) -> T
    ) async throws(StudioError) -> T {
        try checkModelFileIdle()
        let (environment, run) = (environment, ReadRun())
        readRuns.append(run)
        defer { endRead(run) }
        let stopped: @Sendable () -> Bool = { run.cancelled.withLock { $0 } }
        let result = await withTaskCancellationHandler {
            await onJobThread { Result { () throws(ModelFileCheckError) in try body(environment, stopped) } }
        } onCancel: {
            run.cancel()
        }
        switch result {
        case .success(let value): return value
        case .failure(let error):
            guard error == .stopped || stopped() else { throw .transcription(.modelFile(error)) }
            switch run.end.withLock({ $0 }) {
            case .take: throw .readYielded
            case .close: throw .readClosed
            case nil: throw .transcriptionCancelled
            }
        }
    }

    /// The take part of the refusals of `transcribe`: `.busy` while this studio is not idle or
    /// records, and while another studio records, has a pending take, or starts a take. No hash
    /// and no helper of a model file starts then.
    public func checkModelFileIdle() throws(StudioError) {
        try checkIdle()
        guard session.recording == nil,
            !otherStudios().contains(where: { $0.session.recording != nil || $0.isStarting })
        else { throw .busy }
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
