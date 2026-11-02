import DirigibleAudio
import Foundation

/// The texts of a model file of the user that need more than a key (decision 0065, D8).
extension L10n {
    /// The text of a failed step on the model file at `url`: a file that is gone names the file (U22).
    static func message(for error: StudioError, modelFile url: URL) -> String {
        if case .transcription(.modelFile(.unreadable(errno: ENOENT))) = error {
            return errorTranscribeFileMissing.format(url.lastPathComponent)
        }
        return message(for: error)
    }
}
