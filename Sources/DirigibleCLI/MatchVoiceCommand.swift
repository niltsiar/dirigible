import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

extension TrackCommand {
    struct MatchVoice: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "match-voice",
            abstract: "Match the voice of tracks to a reference voice with a live EQ curve.",
            discussion: """
                With --reference, the command reads the reference clip (only --from to --to, timeline \
                frames, when given) and each track, and gives each track a match: a curve of 25 band gains \
                that moves its spectrum toward the reference, at --amount percent (1 to 100). A new match \
                takes 75, and a replace keeps the amount of the track unless you give one. Each match is \
                on. The command changes no audio file. Each side needs 10 s of voice. Music and effects \
                tracks are left out. With --amount, --bypass on|off, or both, and no --reference, the \
                command changes the match of tracks that have one. --remove removes the match. A line for \
                each track: "<track>: match <amount> % (+<boost> dB, -<cut> dB)" with ", bypassed" after \
                it for a bypassed match, "<track>: left out, a music or effects track", "<track>: match \
                removed", or "<track>: no match". Exit 64 when no track is named, --from comes without \
                --to or without --reference, --from is at or after --to, --amount is not from 1 to 100, \
                --bypass is not on or off, --bypass comes with --reference, or --remove comes with another \
                option. Exit 1 when a clip or a track is unknown, the range is not inside the reference \
                clip, a track has no match to change, a side has under 10 s of voice, or a source WAV is \
                missing, short, or unreadable. Exit 2 when the package cannot be read or written, is \
                locked, or has a take that is not finalized. Control-C leaves the package as it was and \
                exits 130.
                """)

        @OptionGroup var package: PackageArgument
        @Argument(help: "A track. Give one or more.") var tracks: [String] = []
        @Option(help: "The clip ID of the reference voice.") var reference: String?
        @Option(parsing: .unconditional, help: "With --reference: the first timeline frame to learn, with --to.")
        var from: Int?
        @Option(parsing: .unconditional, help: "With --reference: the timeline frame after the part, with --from.")
        var to: Int?
        @Option(parsing: .unconditional, help: "The amount in whole percent, 1 to 100.") var amount: Int?
        @Option(help: "on plays the track with no match, off plays it with the match.") var bypass: String?
        @Flag(help: "Remove the match of the tracks.") var remove = false

        func work() throws(ValidationError) -> MatchWork {
            var bypassed: Bool?
            if let bypass {
                guard let word = MatchWork.bypass(word: bypass) else { throw ValidationError("--bypass is on or off.") }
                bypassed = word
            }
            switch MatchWork.parse(
                tracks: tracks, reference: reference, from: from, to: to, amount: amount, bypass: bypassed,
                remove: remove)
            {
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

        /// The error line and the exit code of a match that changes nothing. A source that does
        /// not read exits 1 as an unknown clip does. Control-C gives the status of the default action.
        func failure(_ error: StudioError) -> ExitCode {
            switch error {
            case .matchCancelled: ExitCode(128 + SIGINT)
            default: fail(error.message(package: package.path), code: editRefused)
            }
        }
    }
}
