import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

extension ClipCommand {
    struct LevelOverTime: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "level-over-time",
            abstract: "Even out the level inside clips over time with a ride gain layer.",
            discussion: """
                The command measures the loudness of the speech in each run of clips of one file and \
                writes a second gain layer of each clip, the ride: a gain between -6 and +6 dB that \
                follows the loudness. A pause keeps the gain of the last speech. The ride adds to the \
                gain points of the clip. It changes no audio file. clip envelope edits the points and \
                leaves the ride as it is. A line for each clip: "<clip>: leveled, <lowest> to <highest> \
                dB, <n> points", or "<clip>: no measurement" for a clip with no loudness to measure; \
                that clip has no ride. A second call replaces the ride of the clip. --clear removes the \
                ride and reads no audio: "<clip>: ride removed", or "<clip>: no ride" for a clip with \
                no ride to remove. --clear with --from and --to removes the ride only inside that range \
                of timeline frames, with a ramp of 500 ms at each edge, and no other clip changes what \
                it plays. Exit 64 when --from comes without --to, without --clear, or with --from at or \
                after --to. Exit 1 when a clip is unknown, or a source WAV is missing, short, or \
                unreadable. Exit 2 when the package cannot be read or written, is locked, or has a take \
                that is not finalized. Control-C leaves the package as it was and exits 130.
                """)

        @OptionGroup var package: PackageArgument
        @Argument(help: "A clip. Give one or more.") var clips: [String] = []
        @Flag(help: "Remove the ride in place of making it.") var clear = false
        @Option(parsing: .unconditional, help: "With --clear: the first timeline frame of the range, with --to.")
        var from: Int?
        @Option(parsing: .unconditional, help: "With --clear: the timeline frame after the range, with --from.")
        var to: Int?

        func work() throws(ValidationError) -> RideWork {
            switch RideWork.parse(clips: clips, clear: clear, from: from, to: to) {
            case .success(let work): return work
            case .failure(let error): throw ValidationError(error.message)
            }
        }

        func validate() throws { _ = try work() }

        func run() throws {
            let work = try work()
            let interrupt = cancelOnInterrupt()
            defer { interrupt.source.cancel() }
            let lines = try editPackage(package, ripple: false, writeUnchanged: false, refused: failure) {
                session, _ throws(StudioError) in
                try work.run(&session, package: package.url, isCancelled: interrupt.isCancelled)
            }
            for line in lines { print(line) }
        }

        /// The error line and the exit code of a ride that changes nothing. A source that does not
        /// read exits 1 as an unknown clip does. Control-C gives the status of the default action.
        func failure(_ error: StudioError) -> ExitCode {
            switch error {
            case .rideCancelled: ExitCode(128 + SIGINT)
            case .session, .rideFault: fail(error.message(package: package.path), code: editRefused)
            default: fail(error.message(package: package.path), code: packageError)
            }
        }
    }
}
