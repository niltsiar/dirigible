import DirigibleAudio
import DirigibleCore
import Foundation

/// Why a transcription on the files changes nothing.
package enum TranscribeFailure: Error {
    case session(SessionError)
    /// The model folder has no file of the model: its path.
    case noModel(String)
    /// The model file does not have the byte count and the SHA-256 of the catalog: its path.
    case checksum(String)
    case engine(TranscribeError)
    case cancelled

    package var message: String {
        switch self {
        case .session(let error): error.message
        case .noModel(let path): "no whisper model at \(path)"
        case .checksum(let path): "the whisper model at \(path) does not match its checksum"
        case .engine(let error): error.message
        case .cancelled: "the transcription was cancelled."
        }
    }
}

/// The work of a `transcribe` call or command after its arguments are checked (decision 0065). It
/// is the one owner of the model check, the steps on the files, and the texts of
/// `dirigible transcribe` and the tool `transcribe`. In the app, `liveJob` runs `Studio.transcribe`,
/// which downloads a missing model; on the files, nothing downloads.
package struct TranscribeWork: Sendable {
    let track: TrackID
    let language: WhisperLanguage
    let model: WhisperModelChoice
    /// The transcript name. Nil is the track name.
    let name: String?

    /// No `model` and no `modelFile` is the model base. The error text: an unknown language, an
    /// unknown model name, or both a model and a model file, named as `spelling` spells them.
    package init(
        track: String, language: String, model: String?, modelFile: String?, name: String?,
        spelling: OptionSpelling = .tool
    ) throws(ToolError) {
        guard let parsed = WhisperLanguage(language) else {
            throw ToolError("unknown language \(language): give auto or a whisper language code, for example es")
        }
        let choice: WhisperModelChoice
        switch (model, modelFile) {
        case (.some, .some): throw ToolError("Give \(spelling("model")) or \(spelling("model_file")), not both.")
        case (nil, let file?): choice = .file(URL(filePath: file), passed: nil)
        case (let given, nil):
            let entry = given ?? WhisperModel.base.rawValue
            guard let catalog = WhisperModel(rawValue: entry) else { throw ToolError("unknown model \(entry)") }
            choice = .catalog(catalog)
        }
        (self.track, self.language, self.model, self.name) = (TrackID(track), parsed, choice, name)
    }

    /// The lines of a transcription, as `importLines` gives them for an import, then the SHA-256 of
    /// a model file of the user.
    static func lines(
        id: TranscriptID?, kept: Int, skipped: Int, untimed: Int, dropped: [String], modelFile: PassedModelFile?
    ) -> [String] {
        TranscriptWork.importLines((id, kept, skipped, untimed, 0, dropped), cues: false)
            + (modelFile.map { ["Model file SHA-256: \($0.sha256)"] } ?? [])
    }

    /// The transcription of the track in `session` with the model of the model folder (decision
    /// 0065 D2), or with a model file of the user after its check in the helper `dirigible model
    /// check` (D8), and its lines. The flag is read last before the caller saves: a cancel keeps
    /// `session` as it was. No kept word leaves `session` as it was.
    package func run(
        _ session: inout Session, package: URL, log: DiagnosticLog = .disabled,
        progress: @escaping (Double) -> Void = { _ in }, isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws(TranscribeFailure) -> [String] {
        let (track, checked) = try model(of: session, isCancelled: isCancelled)
        let done: TranscribedWords?
        do throws(TranscribeError) {
            done = try transcribeTrack(
                track, of: session, package: package, language: language, model: checked, log: log,
                isCancelled: isCancelled, progress: progress)
        } catch {
            throw .engine(error)
        }
        guard let words = done, !isCancelled() else { throw .cancelled }
        let added: (id: TranscriptID?, kept: Int, skipped: Int, dropped: [String])
        do throws(SessionError) {
            added = try session.addTranscript(words.words, name: name ?? track.name, derived: [])
        } catch {
            throw .session(error)
        }
        let modelFile: PassedModelFile? = if case .file(let record) = checked.source { record } else { nil }
        return Self.lines(
            id: added.id, kept: added.kept, skipped: added.skipped, untimed: words.untimed, dropped: added.dropped,
            modelFile: modelFile)
    }

    /// The track and the checked model. The helper of a model file of the user starts only after
    /// the track is found.
    private func model(of session: Session, isCancelled: @escaping @Sendable () -> Bool) throws(TranscribeFailure)
        -> (Track, CheckedModel)
    {
        switch model {
        case .catalog(let entry):
            let file = WhisperModelStore.folder().appending(path: entry.fileName)
            guard FileManager.default.fileExists(atPath: file.path) else { throw .noModel(file.path) }
            guard let track = session.track(track) else { throw .session(.unknownTrack(track)) }
            guard let checked = entry.checked(at: file) else { throw .checksum(file.path) }
            return (track, checked)
        case .file(let url, let passed):
            guard let track = session.track(track) else { throw .session(.unknownTrack(track)) }
            do throws(ModelFileCheckError) {
                return (track, try ModelFileCheck.run(url, passed: passed, stop: isCancelled))
            } catch {
                switch error {
                case .unreadable(errno: ENOENT): throw .noModel(url.path)
                case .stopped: throw .cancelled
                default: throw .engine(.modelFile(error))
                }
            }
        }
    }

    /// The job of a tool call on the files, under the package lock. No kept word writes nothing.
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        do throws(EditFailure<TranscribeFailure>) {
            let lines = try editPackageCore(
                package, ripple: false, touchesClips: true, writeUnchanged: false, log: control.log
            ) {
                session, _ throws(TranscribeFailure) in
                try run(
                    &session, package: package, progress: { control.report($0) },
                    isCancelled: { control.isCancelled() })
            }
            return lines.joined(separator: "\n")
        } catch .body(.cancelled) {
            // A cancelled call gets no answer, so no one reads this text.
            throw ToolError(cancelledMessage)
        } catch {
            throw ToolError(error.message(package: path))
        }
    }
}
