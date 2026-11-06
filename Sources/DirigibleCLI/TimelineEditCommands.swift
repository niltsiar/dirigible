import ArgumentParser
import DirigibleCore
import Foundation

extension ClipCommand {
    struct CloseGaps: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "close-gaps",
            abstract:
                "On each track, move each clip after the first one to the end of the clip before it. "
                + "No other clip and no marker moves. Write the ID of each moved clip.")
        @OptionGroup var package: PackageArgument
        @Argument var clips: [String]

        func run() throws {
            let moved = try editPackage(package, ripple: false) { session throws(SessionError) in
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
            try editPackage(package, ripple: false) { session throws(SessionError) in
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
            try editPackage(package, ripple: false) { session throws(SessionError) in
                try session.slip(clips.map { ClipID($0) }, by: Frames(by))
            }
        }
    }
}
