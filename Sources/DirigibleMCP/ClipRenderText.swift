import DirigibleAudio
import DirigibleCore

extension ClipRenderError {
    /// The CLI and tool text (decisions 0054 and 0064). Each case but `session`, `trackRole`, and
    /// `effectUnavailable` names the clip render, never an import; those two name the noise reduction.
    /// No `default` case: a new error case does not compile until it has a message.
    package var message: String {
        switch self {
        case .space(let needed, let free):
            "the clip render needs \(needed) free bytes, and the disk has \(free)."
        case .write(let file, let code): "the clip render cannot write \"\(file)\" (errno \(code))."
        case .sourceUnreadable(let file, let code):
            "the clip render cannot read the source \"\(file)\" (errno \(code))."
        case .sourceMissing(let file): "the clip render cannot find the source \"\(file)\" in Clips/."
        case .notDownloaded(let file):
            "the clip render cannot read the source \"\(file)\": it is not on this Mac. Download it first."
        case .cancelled: "the clip render was cancelled."
        case .session(let error): error.message
        case .trackRole(let clip, let role):
            "the noise reduction refuses clip \"\(clip)\": its track has the role \(role.rawValue), "
                + "and the noise reduction keeps only voices."
        case .mixedTreatments(let clips):
            "the clip render refuses clips \(clips.map { "\"\($0)\"" }.joined(separator: ", ")): they share "
                + "one new file but have different settings."
        case .effectUnavailable(let status):
            "the noise reduction of macOS (AUSoundIsolation) did not load (status \(status))."
        case .engine(let status): "the clip render stopped: the audio engine failed (status \(status))."
        case .stillOverFullScale(let file): "the clip render made \"\(file)\" louder than full scale, so it clips."
        case .cornerTooHigh(let hertz, .hertz(let limit)):
            "the clip render refuses \(hertz) Hz: the session rate takes a filter corner of \(limit) Hz at most."
        case .cornerTooHigh(let hertz, .lowestRate(let rate)):
            "the clip render refuses \(hertz) Hz: the effect needs a session rate of \(rate) Hz or more."
        case .nonFiniteSample(let file):
            "the clip render refuses \"\(file)\": a rendered sample is not a number, so it writes nothing."
        }
    }
}
