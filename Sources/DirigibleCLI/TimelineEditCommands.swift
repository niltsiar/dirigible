import ArgumentParser
import DirigibleCore
import DirigibleMCP
import Foundation

/// `EditRules.overlapMode` of a word.
func parseOverlapMode(_ text: String) throws -> OverlapMode {
    guard let mode = EditRules.overlapMode(text) else {
        throw ValidationError("A mode is overwrite, no-overlap, or crossfade.")
    }
    return mode
}

extension ClipCommand {
    struct Shuffle: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Move a clip as a ripple (decision 0037): close its old place on its track, open room at the new "
                + "start on the target track, and put the clip there. The markers follow the ripple. No other track "
                + "moves. The start is a frame of the timeline after the old place closes.")
        @OptionGroup var package: PackageArgument
        @Argument var clip: String
        @Option var track: String
        @Option(parsing: .unconditional, help: "The new timeline frame of the first clip frame.") var start: Int

        func run() throws {
            try editPackage(package, ripple: true, touchesClips: false) { session throws(SessionError) in
                try session.shuffle(ClipID(clip), to: TrackID(track), start: Frames(start))
            }
        }
    }

    struct CloseGaps: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "close-gaps",
            abstract:
                "On each track, move each clip after the first one to the end of the clip before it. "
                + "No other clip and no marker moves. Write the ID of each moved clip.")
        @OptionGroup var package: PackageArgument
        @Argument var clips: [String]

        func run() throws {
            let moved = try editPackage(package, ripple: false, touchesClips: false) { session throws(SessionError) in
                try session.closeGaps(clips.map { ClipID($0) })
            }
            for id in moved { print(id) }
        }
    }

    struct Roll: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Move the join between a clip and the clip that touches its end (decision 0036). "
                + "The left clip grows by --by frames and the right clip loses them at its start.")
        @OptionGroup var package: PackageArgument
        @Argument(help: "The left clip of the join.") var clip: String
        @Option(parsing: .unconditional, help: "The frames to move the join; negative moves it left.") var by: Int

        func run() throws {
            try editPackage(package, ripple: false, touchesClips: false) { session throws(SessionError) in
                try session.roll(ClipID(clip), by: Frames(by))
            }
        }
    }

    struct Slip: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Move the audio under clips and keep their place, length, and fades (decision 0036). "
                + "All clips move, or none.")
        @OptionGroup var package: PackageArgument
        @Argument var clips: [String]
        @Option(
            parsing: .unconditional, help: "The frames to move the audio; negative plays earlier audio of the file.")
        var by: Int

        func run() throws {
            try editPackage(package, ripple: false, touchesClips: false) { session throws(SessionError) in
                try session.slip(clips.map { ClipID($0) }, by: Frames(by))
            }
        }
    }
}
