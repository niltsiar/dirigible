/// The value types of the transcribe seam (decision 0065, D6). Times are in piece time, in ticks of
/// 10 ms: the time unit of whisper.cpp tokens.
public struct TimedWord: Hashable, Sendable {
    public var text: String
    public var start: Int
    public var end: Int

    public init(text: String, start: Int, end: Int) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// One text token of a whisper.cpp result. `bytes` can end inside a UTF-8 character, which the
/// next token completes.
struct WhisperToken: Hashable, Sendable {
    var bytes: [UInt8]
    var start: Int
    var end: Int
    var isSpecial: Bool
}

/// The language that a job asks the engine for.
public enum WhisperLanguage: Hashable, Sendable {
    /// whisper.cpp detects the language from the first 30 s of the first piece that gives a word.
    case automatic
    /// A code of `whisper_lang_str`, for example "es".
    case code(String)
}

/// The words of each piece of a job, in piece time, and the language of the job.
public struct Transcription: Hashable, Sendable {
    public var pieces: [[TimedWord]]
    public var language: String

    public init(pieces: [[TimedWord]], language: String) {
        self.pieces = pieces
        self.language = language
    }
}

/// What one piece gives: its words and the detected language, or a stop.
enum PieceOutcome: Hashable, Sendable {
    case words([TimedWord], language: String)
    case stopped
}

public enum TranscribeError: Error, Hashable, Sendable {
    /// `whisper_init` gave no context for a checked model file.
    case modelLoad
    /// `whisper_full` returned this non-zero code with the stop flag clear.
    case engine(code: Int32)
}
