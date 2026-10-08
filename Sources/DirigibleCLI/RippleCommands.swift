import ArgumentParser
import DirigibleCore

/// The ripple edits (decision 0037). No `--track` means all tracks. A split take exits 3. Ripple
/// Cut has no command: `excerpt` does not change the package, and `clip ripple-delete` makes the
/// edit.
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
            guard EditRules.positiveRange(from: range.from, to: range.to) != nil else {
                throw ValidationError("--from must be less than --to.")
            }
        }

        func run() throws {
            try editPackage(package, ripple: true) { session throws(SessionError) in
                try session.rippleDelete(range.frames, on: EditRules.tracks(track, of: session))
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
                try session.rippleInsert(Frames(length), at: Frames(at), on: EditRules.tracks(track, of: session))
            }
        }
    }
}

extension ClipCommand {
    struct RippleTrim: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Move one edge of a clip and ripple the span on the tracks: the later clips and the markers move "
                + "with the edge. The clip start stays.")
        @OptionGroup var package: PackageArgument
        @Argument var clip: String
        @Option(help: "start or end.", transform: parseEdge) var edge: Fades.Edge
        @Option(
            parsing: .unconditional,
            help: "The frames to move the edge; negative moves left. At the start edge, positive removes audio.")
        var by: Int
        @Option(help: "A track. Give none for all tracks, or one or more. The track of the clip always ripples.")
        var track: [String] = []

        func run() throws {
            try editPackage(package, ripple: true) { session throws(SessionError) in
                try session.rippleTrim(
                    ClipID(clip), edge: edge, by: Frames(by), on: EditRules.tracks(track, of: session))
            }
        }
    }
}

private func parseEdge(_ text: String) throws -> Fades.Edge {
    guard let edge = EditRules.edge(text) else { throw ValidationError("An edge is start or end.") }
    return edge
}
