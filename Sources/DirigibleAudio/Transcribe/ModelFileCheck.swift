import Foundation

/// The check of a model file of the user (decision 0065, D8). The parse of `WhisperModelFile`
/// cannot find each file that ends the process in whisper.cpp, so a helper process loads the file
/// and runs a trial: a bad file ends the helper, not the caller. This file owns both sides of the
/// helper protocol: the helper body, its output line, its exit status, and their reader.
public enum ModelFileCheck {
    /// The signals of a process death in the parse, the loader, or `whisper_full`. SIGTRAP and
    /// SIGILL are the Swift traps.
    private static let handledSignals: [Int32] = [SIGABRT, SIGSEGV, SIGFPE, SIGBUS, SIGILL, SIGTRAP]
    /// The seconds between two reads of the stop check while the helper runs.
    private static let stopPoll = 0.25
    /// The seconds from SIGTERM to SIGKILL after a stop.
    private static let killDelay = 0.5

    /// The body of `dirigible model check <path>`: the parse, the SHA-256, and the trial. A pass
    /// prints one line of `line(_:)` and exits 0. A refusal prints one `Error:` line on stderr
    /// and exits 1. A death in the C code exits 128 + signal.
    public static func helperMain(path: String) -> Never {
        for code in handledSignals { signal(code) { _exit(128 + $0) } }
        #if DEBUG
            // The process death of the tests, as a loader assert, with no model file.
            if ProcessInfo.processInfo.environment["DIRIGIBLE_MODEL_CHECK_ABORT"] == "1" { abort() }
        #endif
        let url = URL(filePath: path)
        let file: WhisperModelFile
        do { file = try WhisperModelFile.read(url) } catch { refuse(message(error)) }
        let hash: String
        do { hash = try sha256(of: url) } catch { refuse(message(error)) }
        let record = PassedModelFile(sha256: hash, facts: file.facts)
        do { try trial(CheckedModel(source: .file(record), url: url)) } catch { refuse(message(error)) }
        print(line(record))
        fflush(stdout)
        exit(0)
    }

    /// The job's engine with no VAD (with the VAD of the job, 1 s of noise runs no decoder) and the
    /// job's `whisper_full` params, on 1 s of seeded noise.
    private static func trial(_ model: CheckedModel) throws(TranscribeError) {
        let engine = try WhisperEngine(model: model, vad: nil, log: .disabled)
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        let noise = (0..<16_000).map { _ -> Float in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Float(Int64(bitPattern: state) % 1_000) / 10_000
        }
        _ = try engine.transcribe(piece: noise, language: .code("en"), stop: StopFlag())
    }

    private static func refuse(_ message: String) -> Never {
        try? FileHandle.standardError.write(contentsOf: Data("Error: \(message)\n".utf8))
        exit(1)
    }

    private static func message(_ error: ModelFileError) -> String {
        switch error {
        case .notWhisperModel: "The file is not a ggml whisper model."
        case .unsupported(let reason): "The model file has a value that Dirigible cannot run: \(reason)."
        case .truncated: "The model file ends before its last part."
        case .damaged(let reason): "The model file is damaged: \(reason)."
        case .unreadable(let code): "The model file cannot be read: \(String(cString: strerror(code)))."
        }
    }

    /// The hash of the helper has no stop, so only `.unreadable` comes.
    private static func message(_ error: ModelFileCheckError) -> String {
        guard case .unreadable(let code) = error else { return "\(error)" }
        return message(ModelFileError.unreadable(errno: code))
    }

    private static func message(_ error: TranscribeError) -> String {
        switch error {
        case .modelLoad: "whisper.cpp did not load the model file."
        case .engine(let code): "The trial transcription failed with code \(code)."
        default: "The trial transcription failed: \(error)."
        }
    }

    /// The output line of a pass, for example
    /// `sha256=8187... audio_layers=4 text_layers=4 n_mels=80 multilingual=yes`.
    private static func line(_ record: PassedModelFile) -> String {
        let facts = record.facts
        return "sha256=\(record.sha256) audio_layers=\(facts.audioLayers) text_layers=\(facts.textLayers) "
            + "n_mels=\(facts.melCount) multilingual=\(facts.isMultilingual ? "yes" : "no")"
    }

    /// The record of a `line(_:)`, else nil.
    private static func record(fromLine text: String) -> PassedModelFile? {
        var fields: [Substring: Substring] = [:]
        for field in text.split(separator: " ") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            fields[parts[0]] = parts[1]
        }
        guard let hash = fields["sha256"], hash.count == 64, hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
            let audio = fields["audio_layers"].flatMap({ Int($0) }),
            let text = fields["text_layers"].flatMap({ Int($0) }),
            let mels = fields["n_mels"].flatMap({ Int($0) }),
            let multilingual = fields["multilingual"], ["yes", "no"].contains(multilingual)
        else { return nil }
        return PassedModelFile(
            sha256: String(hash),
            facts: WhisperModelFacts(
                audioLayers: audio, textLayers: text, melCount: mels, isMultilingual: multilingual == "yes"))
    }

    /// The signal of a helper that exits with 128 + a handled signal, else nil.
    private static func handledSignal(exitStatus status: Int32) -> Int32? {
        handledSignals.contains(status - 128) ? status - 128 : nil
    }

    /// Checks the model file at `url` with `helper` (`<helper> model check <path>`), on the calling
    /// thread, which it blocks: run it on the job thread, never on the main actor. Only a regular
    /// file opens (EFTYPE). When the SHA-256 of the file is the one of `passed`, no helper runs and
    /// the facts come from `passed`. `stop` is read before each 1 MiB chunk of the hash, before the
    /// helper starts, and every `stopPoll` seconds while it runs; a set stop ends the helper
    /// (SIGTERM, then SIGKILL after `killDelay` seconds) and throws `.stopped` after the helper is
    /// gone.
    public static func run(_ url: URL, helper: URL, passed: PassedModelFile?, stop: @Sendable () -> Bool)
        throws(ModelFileCheckError) -> CheckedModel
    {
        let hash = try OpenModelFile(url).sha256(stop: stop)
        if let passed, passed.sha256 == hash { return CheckedModel(source: .file(passed), url: url) }
        if stop() { throw .stopped }
        guard FileManager.default.fileExists(atPath: helper.path) else { throw .helperMissing(path: helper.path) }

        let output: HelperOutput
        do { output = try HelperOutput() } catch { throw notStarted(helper, error) }
        defer { output.remove() }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["model", "check", url.path]
        process.standardOutput = output.stdout
        process.standardError = output.stderr
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do {
            try process.run()
        } catch {
            throw notStarted(helper, error)
        }
        while ended.wait(timeout: .now() + stopPoll) == .timedOut {
            guard stop() else { continue }
            process.terminate()
            if ended.wait(timeout: .now() + killDelay) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                ended.wait()
            }
            throw .stopped
        }

        let status = process.terminationStatus
        if process.terminationReason == .uncaughtSignal { throw .helperStopped(signal: status) }
        if let signal = handledSignal(exitStatus: status) { throw .helperStopped(signal: signal) }
        guard status == 0 else { throw .refused(output.errorLine()) }
        guard let record = record(fromLine: output.outputLine()) else { throw .refused(output.outputLine()) }
        guard record.sha256 == hash else { throw .changedDuringCheck }
        return CheckedModel(source: .file(record), url: url)
    }

    /// The helper of the process whose executable is `executable`, with its links resolved: for the
    /// executable in `Contents/MacOS` of the app, `Contents/Helpers/dirigible`; else the `dirigible`
    /// beside it, which is the CLI itself or the CLI of a `swift build` folder.
    public static func helper(executable: URL) -> URL {
        let folder = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        guard folder.lastPathComponent == "MacOS" else { return folder.appending(path: "dirigible") }
        return folder.deletingLastPathComponent().appending(path: "Helpers/dirigible")
    }

    private static func notStarted(_ helper: URL, _ error: any Error) -> ModelFileCheckError {
        let error = error as NSError
        return .helperNotStarted(path: helper.path, domain: error.domain, code: error.code)
    }
}

/// The stdout and stderr files of one helper run, in a new temporary folder: files, not pipes, so
/// a long output (a ggml backtrace) cannot block the helper.
private struct HelperOutput {
    let folder: URL
    let stdout: FileHandle
    let stderr: FileHandle

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "dirigible-model-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appending(path: "stdout").path, contents: nil)
        FileManager.default.createFile(atPath: folder.appending(path: "stderr").path, contents: nil)
        stdout = try FileHandle(forWritingTo: folder.appending(path: "stdout"))
        stderr = try FileHandle(forWritingTo: folder.appending(path: "stderr"))
    }

    /// The last line of stdout that is not empty.
    func outputLine() -> String { lastLine("stdout") }

    /// The last line of stderr that is not empty, with no `Error: ` prefix.
    func errorLine() -> String {
        let line = lastLine("stderr")
        return line.hasPrefix("Error: ") ? String(line.dropFirst("Error: ".count)) : line
    }

    func remove() {
        try? stdout.close()
        try? stderr.close()
        try? FileManager.default.removeItem(at: folder)
    }

    private func lastLine(_ name: String) -> String {
        let data = (try? Data(contentsOf: folder.appending(path: name))) ?? Data()
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        return lines.last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}
