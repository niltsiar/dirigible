import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

extension ClipCommand {
    struct SplitStereo: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Split stereo clips into two mono tracks and write one line for each clip.",
            discussion: """
                The command writes two mono 24-bit WAVs in Clips/ for each run of clips of one file, with a \
                10 s handle on each side of the run, and puts two mono tracks under each source track. They \
                are named "<track> L" and "<track> R". The source clips go; the source track and its file \
                stay. A line has the left clip, the right clip, the left track, and the right track, with a \
                tab between them. Exit 1 when a clip is unknown or on a mono track, or a transcript did not \
                load. Exit 2 when the package cannot be read or written, is locked, has a take that is not \
                finalized, has a source WAV that is missing or unreadable, or has too little free disk space.
                """)

        @OptionGroup var package: PackageArgument
        @Argument(help: "A clip on a stereo track. Give one or more.") var clips: [String] = []

        func validate() throws {
            guard !clips.isEmpty else { throw ValidationError("Give one or more clips.") }
        }

        func run() throws {
            let parts = try editPackage(package, ripple: false, touchesClips: true, refused: failure) {
                session, lock throws(SplitError) -> [SplitPart] in
                let split = try splitStereo(
                    clips.map { ClipID($0) }, names: SplitWork.names, of: session, in: package.url,
                    freeBytes: { lock.freeBytes() })
                session = split.session
                return split.parts
            }
            for line in SplitWork.lines(parts) { print(line) }
        }

        /// The error line and the exit code of a split that changed nothing.
        func failure(_ error: SplitError) -> ExitCode {
            switch error {
            case .session: fail(error.message, code: editRefused)
            case .space, .write, .sourceUnreadable, .sourceMissing, .cancelled: fail(error.message, code: packageError)
            }
        }
    }
}
