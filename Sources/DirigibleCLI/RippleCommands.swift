import ArgumentParser
import DirigibleCore
import DirigibleMCP

/// The ripple edits (decision 0037). No `--track` means all tracks. A split take exits 3. Ripple
/// Cut has no command: `excerpt` does not change the package, and `clip ripple-delete` makes the
/// edit.
extension ClipCommand {
    struct RippleDelete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Remove the frames in one or more ranges and move the later clips and the markers left to close "
                + "the gap. A marker in a range goes to its start. Ranges that overlap or touch cut as one range.")
        @OptionGroup var package: PackageArgument
        @Option(parsing: .unconditionalSingleValue, help: "The first frame of a range. Give one or more.")
        var from: [Int] = []
        @Option(
            parsing: .unconditionalSingleValue,
            help: "The frame after the last frame of a range. Give one for each --from, in order.")
        var to: [Int] = []
        @Option(help: "A track. Give none for all tracks, or one or more.") var track: [String] = []

        func validate() throws { _ = try ranges() }

        func run() throws {
            let ranges = try ranges()
            try editPackage(package, ripple: true) { session throws(SessionError) in
                try session.rippleDelete(
                    ranges, on: EditRules.tracks(track, of: session), naming: track.map { TrackID($0) })
            }
        }

        func ranges() throws -> [Range<Frames>] {
            switch EditRules.rippleRanges(from: from, to: to) {
            case .ranges(let ranges): ranges
            case .missing: throw ValidationError("Give one or more --from and --to.")
            case .unpaired: throw ValidationError("Give one --to for each --from.")
            case .notIncreasing(let range):
                throw ValidationError("--from must be less than --to\(from.count > 1 ? " (range \(range))" : "").")
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
                try session.rippleInsert(
                    Frames(length), at: Frames(at), on: EditRules.tracks(track, of: session),
                    naming: track.map { TrackID($0) })
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
                    ClipID(clip), edge: edge, by: Frames(by), on: EditRules.tracks(track, of: session),
                    naming: track.map { TrackID($0) })
            }
        }
    }
}

private func parseEdge(_ text: String) throws -> Fades.Edge {
    guard let edge = EditRules.edge(text) else { throw ValidationError("An edge is start or end.") }
    return edge
}
