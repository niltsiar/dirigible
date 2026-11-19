import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

extension ClipCommand {
    struct Sync: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sync",
            abstract: "Move a clip onto its audio on another track, by the waveform.",
            discussion: """
                The command reads the clip and the track --to and finds the one move that matches their \
                waveforms. Use it for a recording with no shared clock with the track, for example a guest \
                recording and the call track. The clip keeps its ID, the clips under its new place are cut, \
                and a new start before frame 0 cuts the head of the clip. The command changes no audio file. \
                It searches --within seconds on each side of the clip, 1800 by default; a longer search than \
                the session allows exits 64 with the largest --within for the clip. The first line is \
                "moved <clip> by <+|-><seconds> s (<frames> frames), match <score>". Then "the lag changes \
                by <ms> ms across the clip" when the lag changes along the clip by over 20 ms, or "the \
                drift was not measured: the clip is shorter than 60 s", or "the drift was not measured: \
                only one part of the clip matched", then "cut <seconds> s at the head", then "replaced \
                audio of <clip>, <clip>" with each other clip that the move cut. The command moves the whole \
                clip by one lag and does not correct a drift. With --json, one line with clip, frames, \
                seconds, match, spread, headCut, and replaced; spread and headCut are in frames, spread is \
                null when the drift was not measured, and replaced lists the IDs of the cut clips. Exit 64 \
                when --within is not a whole number of seconds from 1, or is over the longest search, or the \
                clip is longer than the longest span. Exit 1 when the clip or the track is unknown, the \
                track is the track of the clip or has no audio near the clip, or the audio of the clip is not \
                on the track: then nothing changes. Exit 2 when an audio file is missing or unreadable, a file cannot open, or \
                the package cannot be read or written, is locked, or has a take that is not finalized. \
                Control-C leaves the package as it was and exits 130.
                """)

        @OptionGroup var package: PackageArgument
        @Argument(help: "The clip to move.") var clip: String
        @Option(help: "The track that holds the same audio.") var to: String
        @Option(parsing: .unconditional, help: "The search distance on each side of the clip in seconds.")
        var within: Int?
        @Flag(help: "Write one line of JSON in place of the text.") var json = false

        func work() throws(ValidationError) -> SyncWork {
            switch SyncWork.parse(clip: clip, to: to, within: within, front: .commandLine) {
            case .success(let work): return work
            case .failure(let error): throw ValidationError(error.message)
            }
        }

        func validate() throws { _ = try work() }

        func run() throws {
            let work = try work()
            let interrupt = cancelOnInterrupt()
            defer { interrupt.source.cancel() }
            let moved = try editPackage(package, ripple: false, writeUnchanged: false, refused: failure) {
                session, _ throws(SyncRefusal) in
                try work.run(&session, package: package.url, isCancelled: interrupt.isCancelled)
            }
            print(json ? moved.json : moved.lines.joined(separator: "\n"))
        }

        /// The error line and the exit code of a sync that changes nothing. A bad argument exits 64, a
        /// refusal of the session or no match exits 1, and a file that does not read exits 2.
        /// Control-C gives the status of the default action.
        func failure(_ refusal: SyncRefusal) -> ExitCode {
            let text = refusal.message(package: package.path)
            switch refusal {
            case .argument: return fail(text, code: ExitCode.validationFailure.rawValue)
            case .studio(.syncCancelled): return ExitCode(128 + SIGINT)
            case .studio(.syncNoMatch), .studio(.session): return fail(text, code: editRefused)
            case .studio: return fail(text, code: packageError)
            }
        }
    }
}
