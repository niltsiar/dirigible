import ArgumentParser
import DirigibleAudio

struct ModelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model", abstract: "Check a whisper model file.", subcommands: [Check.self])
}

extension ModelCommand {
    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check that a ggml whisper model file loads and transcribes.",
            discussion: """
                The app runs this command as the helper of a model file check (decision 0065, D8), so a bad \
                file ends this process, not the app. It parses the file, then runs a trial transcription of \
                1 s of noise. A pass prints one line with the SHA-256 and the facts of the file and exits 0. \
                A refusal prints the reason on stderr and exits 1. A crash in whisper.cpp exits 128 plus the \
                signal number, for example 134 for SIGABRT. It reads no package and changes none.
                """)

        @Argument(help: ArgumentHelp("The ggml whisper model file.", valueName: "path"))
        var path: String

        func run() { ModelFileCheck.helperMain(path: path) }
    }
}
