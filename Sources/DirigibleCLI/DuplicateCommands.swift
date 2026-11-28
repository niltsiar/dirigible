import ArgumentParser
import DirigibleCore
import Foundation

extension ClipCommand {
    struct Duplicate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Copy a range of tracks and paste the copy at the end of the range, over the clips there (decision "
                + "0053). Nothing moves. Write the pasted IDs.")
        @OptionGroup var package: PackageArgument
        @OptionGroup var range: FrameRange
        @Option(help: "A track to copy and paste on. Give one or more.") var track: [String] = []

        func validate() throws {
            guard !track.isEmpty else { throw ValidationError("Give one or more --track.") }
        }

        func run() throws {
            let targets = track.map { TrackID($0) }
            let pasted = try editPackage(package, ripple: false, touchesClips: false) { session throws(SessionError) in
                try session.duplicate(range.frames, on: targets)
            }
            for id in pasted { print(id) }
        }
    }

    struct DuplicateClips: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Copy whole clips with their time and track offsets, and paste the copy after the last of them, over "
                + "the clips there (decision 0053). Nothing moves. Write the pasted IDs.")
        @OptionGroup var package: PackageArgument
        @Argument var clips: [String]

        func run() throws {
            let ids = clips.map { ClipID($0) }
            let pasted = try editPackage(package, ripple: false, touchesClips: false) { session throws(SessionError) in
                try session.duplicate(ids)
            }
            for id in pasted { print(id) }
        }
    }
}
