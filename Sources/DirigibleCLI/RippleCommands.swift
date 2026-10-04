import ArgumentParser
import DirigibleCore

/// The ripple edits (decision 0037). No `--track` means all tracks. A split take exits 3. Ripple
/// Cut has no command: `excerpt` does not change the package, and `clip ripple-delete` makes the edit.
extension ClipCommand {
    struct RippleDelete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Remove the frames in a range and move the later clips and the markers left to close the gap. "
                + "A marker in the range goes to its start.")
        @OptionGroup var package: PackageArgument
        @OptionGroup var range: FrameRange
        @Option(help: "A track. Give none for all tracks, or one or more.") var track: [String] = []

        func validate() throws {
            guard range.from < range.to else { throw ValidationError("--from must be less than --to.") }
        }

        func run() throws {
            try editPackage(package, ripple: true) { session throws(SessionError) in
                try session.rippleDelete(range.frames, on: scope(track, of: session))
            }
        }
    }

    struct RippleInsert: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Insert silence: split the clips at a frame, and move the later clips and the markers right.")
        @OptionGroup var package: PackageArgument
        @Option(parsing: .unconditional, help: "The timeline frame of the insert.") var at: Int
        @Option(parsing: .unconditional, help: "The frames of silence to insert.") var length: Int
        @Option(help: "A track. Give none for all tracks, or one or more.") var track: [String] = []

        func validate() throws {
            guard length >= 0 else { throw ValidationError("--length must not be negative.") }
        }

        func run() throws {
            try editPackage(package, ripple: true) { session throws(SessionError) in
                try session.rippleInsert(Frames(length), at: Frames(at), on: scope(track, of: session))
            }
        }
    }
}

/// The tracks of `--track`, or all tracks when there is none.
private func scope(_ tracks: [String], of session: Session) -> [TrackID] {
    tracks.isEmpty ? session.tracks.map(\.id) : tracks.map { TrackID($0) }
}
