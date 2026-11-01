import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

/// `dirigible transcribe` (decision 0065): whisper.cpp on the clips of one track, with the model of
/// the model folder or a model file of the user (D8). The tool `transcribe` gives the same lines.
struct TranscribeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe the clips of a track with whisper.cpp on this Mac, and add the words as a transcript.",
        discussion: """
            The output is the output of transcript import: the transcript ID, the count of words, and on stderr \
            a line for each kind of skipped word. With no kept word, stdout holds only "Imported 0 words." and \
            the package does not change. The model comes from the model folder: DIRIGIBLE_MODELS_FOLDER, else \
            ~/Library/Application Support/Dirigible/Models. The command downloads nothing: the app downloads \
            the model on first use. With no app bundle, the model folder must also hold the VAD model \
            ggml-silero-v6.2.0.bin. --model-file gives a ggml whisper model file in place of --model: the \
            command checks it first in a helper process, dirigible model check, and the last stderr line \
            gives its SHA-256. Exit 64 for an unknown language or model, or for --model with --model-file. \
            Exit 1 when the model file is missing, does not match its checksum, or fails its check, the track \
            is unknown, or the engine or an audio read fails. Exit 2 when the package cannot be read or \
            written, is locked, or has a take that is not finalized.
            """)

    @OptionGroup var package: PackageArgument
    @Option(help: "The track whose clips to transcribe.") var track: String
    @Option(help: "auto, or a whisper language code, for example es.") var language = "auto"
    @Option(
        help: ArgumentHelp(
            "The model: base (the default), small-q5_1 (more accurate and slower), or large-v3-turbo-q5_0 (most "
                + "accurate and slowest).")
    )
    var model: String?
    @Option(help: ArgumentHelp("A ggml whisper model file, in place of --model.", valueName: "path"))
    var modelFile: String?
    @Option(help: "The transcript name. The default is the track name.") var name: String?

    func validate() throws { _ = try work() }

    func run() throws {
        let work = try work()
        let lines = try editPackage(package, ripple: false, writeUnchanged: false, refused: failure) {
            session, _ throws(TranscribeFailure) in
            try work.run(&session, package: package.url)
        }
        let (stdout, stderr) = TranscriptWork.importOutput(lines)
        print(stdout.joined(separator: "\n"))
        warn(stderr)
    }

    func work() throws(ValidationError) -> TranscribeWork {
        do throws(ToolError) {
            return try TranscribeWork(
                track: track, language: language, model: model, modelFile: modelFile, name: name, spelling: .cli)
        } catch {
            throw ValidationError(error.message)
        }
    }

    /// Each refusal exits 1. The command has no cancel, so `.cancelled` does not come here.
    func failure(_ error: TranscribeFailure) -> ExitCode { fail(error.message, code: editRefused) }
}
