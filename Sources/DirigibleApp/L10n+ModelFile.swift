import DirigibleAudio
import Foundation

/// The texts of a model file of the user that need more than a key (decision 0065, D8).
extension L10n {
    /// The reason of a model file refusal, in the language of `text`. A reason that names a field and its
    /// value keeps that text in the sentence. The switch has no `default`.
    static func reason(_ reason: ModelFileRefusal, text: (L10n) -> String) -> String {
        func format(_ key: L10n, _ argument: any CVarArg) -> String {
            String(format: text(key), locale: .current, argument)
        }
        return switch reason {
        case .file(.notWhisperModel): text(.errorTranscribeFileReasonNotWhisper)
        case .file(.unsupported(let detail)): format(.errorTranscribeFileReasonUnsupported, detail)
        case .file(.truncated): text(.errorTranscribeFileReasonTruncated)
        case .file(.damaged(let detail)): format(.errorTranscribeFileReasonDamaged, detail)
        case .file(.unreadable(let code)): format(.errorTranscribeFileUnreadable, Int(code))
        case .modelLoad: text(.errorTranscribeFileReasonLoad)
        case .engine(let code): format(.errorTranscribeFileReasonEngine, Int(code))
        case .trialFailed: text(.errorTranscribeFileReasonTrial)
        // A helper that gave no code is an older or foreign one: its English line is all there is.
        case .unknown(let line): line
        }
    }

    /// The text of a model file check that gave no checked model (decision 0065, D8). The switch
    /// has no `default`.
    static func message(for error: ModelFileCheckError, text: (L10n) -> String = { $0.text }) -> String {
        switch error {
        case .unreadable(let code): errorTranscribeFileUnreadable.format(Int(code))
        case .helperMissing: errorTranscribeFileHelperMissing.text
        // The error of `Process.run()` can name a false cause: a file with no execute permission
        // gives NSCocoaErrorDomain 4, "doesn't exist". The text gives only the domain and the code.
        case .helperNotStarted(_, let domain, let code): errorTranscribeFileHelperStart.format(domain, code)
        case .refused(let reason):
            String(format: text(.errorTranscribeFileRefused), locale: .current, Self.reason(reason, text: text))
        case .helperStopped(let signal): errorTranscribeFileCrashed.format(Int(signal))
        case .changedDuringCheck: errorTranscribeFileChanged.text
        // A stop ends the job with `.transcriptionCancelled` or `.transcriptionYielded`, not with this case.
        case .stopped: transcribeCanceled.text
        }
    }

    /// The text of a failed step on the model file at `url`: a file that is gone names the file (U22).
    static func message(for error: StudioError, modelFile url: URL) -> String {
        if case .transcription(.modelFile(.unreadable(errno: ENOENT))) = error {
            return errorTranscribeFileMissing.format(url.lastPathComponent)
        }
        return message(for: error)
    }
}
