import CWhisper
import Foundation
import os

/// What one `whisper_full` call gives.
enum WhisperRunOutcome: Hashable, Sendable {
    case finished
    case stopped
    case failed(TranscribeError)
}

/// A set stop flag makes any code a stop: an abort returns -6, -3 in the language detect, or -9 in
/// the decoder, and a stop after the last abort check returns 0. A non-zero code with the flag clear
/// is an engine error.
func whisperOutcome(code: Int32, stopFlagSet: Bool) -> WhisperRunOutcome {
    if stopFlagSet { return .stopped }
    return code == 0 ? .finished : .failed(.engine(code: code))
}

/// One `whisper_context` (decision 0065, D6). Run it on one thread that is not the main actor: each
/// call blocks for the whole decode.
final class WhisperEngine {
    private let context: OpaquePointer
    private let vadPath: String?

    init(model: CheckedModel, vad: URL?, log: DiagnosticLog) throws(TranscribeError) {
        WhisperLog.shared.route(to: log)
        var params = whisper_context_default_params()
        params.use_gpu = false
        guard let context = whisper_init_from_file_with_params(model.url.path, params) else { throw .modelLoad }
        self.context = context
        vadPath = vad?.path
    }

    deinit { whisper_free(context) }

    /// The pieces in order. The flag is read before each piece, and a set flag returns nil with no
    /// `whisper_full` call. With `.automatic`, the language of the first piece that gives a word
    /// goes to each later piece.
    func transcribe(
        pieceCount: Int, language: WhisperLanguage, stop: StopFlag, read: (Int) throws(TranscribeError) -> [Float],
        progress: (Double) -> Void
    ) throws(TranscribeError) -> Transcription? {
        var chosen = language
        var detected = "auto"
        var pieces: [[TimedWord]] = []
        for n in 0..<pieceCount {
            if stop.isSet { return nil }
            switch try transcribe(piece: read(n), language: chosen, stop: stop) {
            case .stopped: return nil
            case .words(let words, let code):
                pieces.append(words)
                if chosen == .automatic { detected = code }
                if chosen == .automatic && !words.isEmpty { chosen = .code(code) }
            }
            progress(Double(n + 1) / Double(pieceCount))
        }
        switch chosen {
        case .automatic: return Transcription(pieces: pieces, language: detected)
        case .code(let code): return Transcription(pieces: pieces, language: code)
        }
    }

    /// One piece of 16 kHz mono samples. It does not read the flag before `whisper_full`, so a set
    /// flag reaches the abort checks. Each NaN or infinite sample is 0.
    func transcribe(piece: [Float], language: WhisperLanguage, stop: StopFlag) throws(TranscribeError)
        -> PieceOutcome
    {
        let samples = piece.map { $0.isFinite ? $0 : 0 }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = 4
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.token_timestamps = true
        params.abort_callback = stop.abortCallback
        params.abort_callback_user_data = stop.userData
        let code: String
        switch language {
        case .automatic: code = "auto"
        case .code(let value): code = value
        }
        let result = code.withCString { language in
            params.language = language
            guard let vadPath else { return whisper_full(context, params, samples, Int32(samples.count)) }
            return vadPath.withCString { vad in
                params.vad = true
                params.vad_model_path = vad
                return whisper_full(context, params, samples, Int32(samples.count))
            }
        }
        switch whisperOutcome(code: result, stopFlagSet: stop.isSet) {
        case .stopped: return .stopped
        case .failed(let error): throw error
        case .finished:
            let words = WordEnds.place(WhisperWords.join(tokens()), samples: samples)
            return .words(words, language: String(cString: whisper_lang_str(whisper_full_lang_id(context))))
        }
    }

    private func tokens() -> [WhisperToken] {
        let endOfText = whisper_token_eot(context)
        var tokens: [WhisperToken] = []
        for segment in 0..<whisper_full_n_segments(context) {
            for index in 0..<whisper_full_n_tokens(context, segment) {
                guard let text = whisper_full_get_token_text(context, segment, index) else { continue }
                tokens.append(
                    WhisperToken(
                        bytes: Array(UnsafeRawBufferPointer(start: text, count: strlen(text))),
                        start: Int(whisper_full_get_token_t0(context, segment, index)),
                        end: Int(whisper_full_get_token_t1(context, segment, index)),
                        isSpecial: whisper_full_get_token_id(context, segment, index) >= endOfText))
            }
        }
        return tokens
    }
}

/// The log of whisper.cpp and ggml goes to the journal of the last engine, never to stderr: the
/// CLI tests compare stderr as text (0011). Warnings and errors only; the info lines of each model
/// load are noise.
final class WhisperLog: Sendable {
    private let target = OSAllocatedUnfairLock(initialState: DiagnosticLog.disabled)

    /// Set once per process, before the first `whisper_init`.
    static let shared: WhisperLog = {
        let sink = WhisperLog()
        let data = Unmanaged.passRetained(sink).toOpaque()
        whisper_log_set(callback, data)
        ggml_log_set(callback, data)
        return sink
    }()

    func route(to log: DiagnosticLog) { target.withLock { $0 = log } }

    private static let callback: ggml_log_callback = { level, text, data in
        guard level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR, let text, let data else { return }
        let log = Unmanaged<WhisperLog>.fromOpaque(data).takeUnretainedValue().target.withLock { $0 }
        let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        log.note(.app, "whisper log", level: .error, ["text": .text(line)])
    }
}

extension WhisperLanguage {
    /// The codes of `whisper_lang_str`, for example "es", in the order of whisper.cpp.
    public static var codes: [String] { (0...whisper_lang_max_id()).map { String(cString: whisper_lang_str($0)) } }

    /// "auto", or a code of `whisper_lang_str`, for example "es". Nil for any other text. It does not
    /// call `whisper_lang_id`, which logs an unknown code to stderr.
    public init?(_ text: String) {
        if text == "auto" {
            self = .automatic
            return
        }
        guard (0...whisper_lang_max_id()).contains(where: { String(cString: whisper_lang_str($0)) == text }) else {
            return nil
        }
        self = .code(text)
    }
}
