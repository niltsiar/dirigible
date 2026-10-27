import DirigibleAudio
import DirigibleCore

extension ClipRenderError {
    /// The CLI and tool text (decision 0054). Each case but `session` names the noise reduction, never
    /// an import. No `default` case: a new error case does not compile until it has a message.
    package var message: String {
        switch self {
        case .space(let needed, let free):
            "the noise reduction needs \(needed) free bytes, and the disk has \(free)."
        case .write(let file, let code): "the noise reduction cannot write \"\(file)\" (errno \(code))."
        case .sourceUnreadable(let file, let code):
            "the noise reduction cannot read the source \"\(file)\" (errno \(code))."
        case .sourceMissing(let file): "the noise reduction cannot find the source \"\(file)\" in Clips/."
        case .notDownloaded(let file):
            "the noise reduction cannot read the source \"\(file)\": it is not on this Mac. Download it first."
        case .cancelled: "the noise reduction was cancelled."
        case .session(let error): error.message
        case .trackRole(let clip, let role):
            "the noise reduction refuses clip \"\(clip)\" on a \(role.rawValue) track: it keeps only voices."
        case .mixedTreatments(let clips):
            "the noise reduction refuses clips \(clips.map { "\"\($0)\"" }.joined(separator: ", ")): they share "
                + "one new file but have different amounts."
        case .effectUnavailable(let status):
            "the noise reduction of macOS (AUSoundIsolation) did not load (status \(status))."
        case .engine(let status): "the noise reduction stopped: the audio engine failed (status \(status))."
        }
    }
}
