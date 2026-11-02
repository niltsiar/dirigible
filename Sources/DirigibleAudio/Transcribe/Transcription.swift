import Foundation

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
    /// The model download failed in the network or at the server: a `URLError`.
    case modelDownload
    /// The model download got no byte from this host before the request limit ended it: a
    /// firewall can hold the connection.
    case modelDownloadNoData(host: String)
    /// A file step in the model folder failed, for example a full disk: the folder and the errno.
    case modelWrite(folder: String, errno: Int32)
    /// The downloaded file does not have the byte count and the SHA-256 of the catalog. The
    /// download deleted it.
    case modelDownloadChecksum
    /// The model file does not have the byte count and the SHA-256 of the catalog.
    case modelChecksum
    /// An audio file of the track did not read: its pool path and the errno.
    case audioRead(file: String, errno: Int32)
    /// No VAD model file is at these paths.
    case vadModelMissing(tried: [String])
    /// No VAD model file is in the app, and the file in the model folder fails its check: its path.
    case vadModelChecksum(file: String)
    /// `whisper_full` returned this non-zero code with the stop flag clear.
    case engine(code: Int32)
    /// The check of a model file of the user gave no checked model.
    case modelFile(ModelFileCheckError)
    /// The model file of the user changed after its passed check, before the engine.
    case modelChanged
    /// The model file of the user is English only, and the job asks for another language.
    case languageNotInModel
}

/// Why the helper refused a model file, as a code and not as English text, so the app writes the
/// reason in its own language (decision 0010). A reason that names a field and its value keeps that
/// text inside the sentence, as an errno does.
public enum ModelFileRefusal: Hashable, Sendable {
    /// The parse refused the file.
    case file(ModelFileError)
    /// whisper.cpp did not load the file in the trial.
    case modelLoad
    /// The engine of the trial failed with this code.
    case engine(code: Int32)
    /// The trial failed in another way.
    case trialFailed
    /// The helper gave no code: its last line.
    case unknown(String)

    /// The English text of the CLI and the tools.
    public var message: String {
        switch self {
        case .file(.notWhisperModel): "The file is not a ggml whisper model."
        case .file(.unsupported(let reason)): "The model file has a value that Dirigible cannot run: \(reason)."
        case .file(.truncated): "The model file ends before its last part."
        case .file(.damaged(let reason)): "The model file is damaged: \(reason)."
        case .file(.unreadable(let code)): "The model file cannot be read: \(String(cString: strerror(code)))."
        case .modelLoad: "whisper.cpp did not load the model file."
        case .engine(let code): "The trial transcription failed with code \(code)."
        case .trialFailed: "The trial transcription failed."
        case .unknown(let line): line
        }
    }
}

/// Why `ModelFileCheck.run` gives no checked model for a model file of the user (decision 0065, D8).
public enum ModelFileCheckError: Error, Hashable, Sendable {
    /// The open or a read of the file for its SHA-256 failed with this errno.
    case unreadable(errno: Int32)
    /// No helper file is at this path: a fault of the install.
    case helperMissing(path: String)
    /// `Process.run()` of the helper threw: the path and the error domain and code.
    case helperNotStarted(path: String, domain: String, code: Int)
    /// The parse or the trial refused the file: the reason of the helper.
    case refused(ModelFileRefusal)
    /// The helper ended by this signal, or exited with 128 + this signal from its handlers.
    case helperStopped(signal: Int32)
    /// The helper read the file with another SHA-256 than the hash before the helper.
    case changedDuringCheck
    /// The stop check was set before the helper ended.
    case stopped
}
