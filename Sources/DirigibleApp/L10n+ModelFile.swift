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

    /// The text of a failed step on the model file at `url`: a file that is gone names the file (U22).
    static func message(for error: StudioError, modelFile url: URL) -> String {
        if case .transcription(.modelFile(.unreadable(errno: ENOENT))) = error {
            return errorTranscribeFileMissing.format(url.lastPathComponent)
        }
        return message(for: error)
    }
}
