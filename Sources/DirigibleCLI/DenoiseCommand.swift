import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

extension ClipCommand {
    struct Denoise: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reduce the noise in clips and write one line for each clip.",
            discussion: """
                The command renders each run of clips of one file through the noise reduction of macOS into \
                a new 24-bit WAV in Clips/, with a 10 s handle on each side of the run, and moves the clips \
                onto it. The source file stays. --reduction is a whole number of dB from 1 to 30; the \
                default is 12. A line has the clip and its new file, with a tab between them. The command \
                refuses a clip on a music or effects track. Exit 1 when a clip is unknown, a clip is on a \
                music or effects track, or the noise reduction does not load. Exit 2 when the package cannot \
                be read or written, is locked, has a take that is not finalized, has a source WAV that is \
                missing or unreadable, has too little free disk space, or the render fails. Control-C \
                leaves the package as it was and exits 130.
                """)

        @OptionGroup var package: PackageArgument
        @Argument(help: "A clip on a track with no role or the dialogue role. Give one or more.")
        var clips: [String] = []
        @Option(
            parsing: .unconditional, help: "The noise reduction in dB, 1 to 30.", transform: parseReduction)
        var reduction = NoiseReduction.standard

        func validate() throws {
            guard !clips.isEmpty else { throw ValidationError("Give one or more clips.") }
        }

        func run() throws {
            let work = ClipRenderWork(clips: clips.map { ClipID($0) }, reduction: reduction)
            let interrupt = cancelOnInterrupt()
            defer { interrupt.source.cancel() }
            let moved = try editPackage(package, ripple: false, refused: failure) {
                session, lock throws(ClipRenderError) in
                try work.render(
                    &session, in: package.url, lock: lock, progress: { _ in }, isCancelled: interrupt.isCancelled)
            }
            for line in ClipRenderWork.lines(moved) { print(line) }
        }

        /// The error line and the exit code of a render that changed nothing. Control-C gives the
        /// status of the default action, with no message.
        func failure(_ error: ClipRenderError) -> ExitCode {
            switch error {
            case .cancelled: ExitCode(128 + SIGINT)
            case .session, .trackRole, .effectUnavailable: fail(error.message, code: editRefused)
            case .space, .write, .sourceUnreadable, .sourceMissing, .notDownloaded, .engine:
                fail(error.message, code: packageError)
            }
        }
    }
}

/// `NoiseReduction(decibels:)` refuses a value outside its range. A text that is not a whole number
/// is refused too.
private func parseReduction(_ text: String) throws -> NoiseReduction {
    guard let decibels = Int(text), let reduction = NoiseReduction(decibels: decibels) else {
        throw ValidationError("A reduction is \(ClipRenderWork.reductionExpected).")
    }
    return reduction
}
