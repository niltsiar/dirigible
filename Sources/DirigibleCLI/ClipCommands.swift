import ArgumentParser
import DirigibleCore

struct ClipCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clip", abstract: "Place, cut, and change clips on tracks.",
        subcommands: [Place.self, Clear.self, Split.self, Move.self, Trim.self, SetGain.self])

    struct Place: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Place a clip and write its ID. The clip overwrites the clips under it.")
        @OptionGroup var package: PackageArgument
        @Option var track: String
        @Option var file: String
        @Option(parsing: .unconditional, help: "The timeline frame of the first clip frame.") var start: Int
        @Option(parsing: .unconditional, help: "The length in frames.") var length: Int
        @Option(parsing: .unconditional, help: "The file frame of the first clip frame.") var offset = 0
        @Option(parsing: .unconditional, help: "The gain in dB.", transform: parseGain) var db: Gain = .zero
        @Option(help: "The clip ID. The default is a new UUID.") var id: String?

        func run() throws {
            let clip = Clip(
                id: id.map { ClipID($0) } ?? ClipID(), file: FileID(file), start: Frames(start), offset: Frames(offset),
                length: Frames(length), gain: db)
            try editPackage(package) { session throws(SessionError) in try session.place(clip, on: TrackID(track)) }
            print(clip.id)
        }
    }

    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove the frames in a range and leave a gap.")
        @OptionGroup var package: PackageArgument
        @Option var track: String
        @OptionGroup var range: FrameRange

        func run() throws {
            try editPackage(package) { session throws(SessionError) in
                try session.clear(range.frames, on: TrackID(track))
            }
        }
    }

    struct Split: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Split a clip and write the ID of the right part.")
        @OptionGroup var package: PackageArgument
        @Argument var clip: String
        @Option(parsing: .unconditional, help: "The timeline frame of the split.") var at: Int
        @Option(help: "The ID of the right part. The default is <clip>@<frame>.") var rightID: String?

        func run() throws {
            let right = try editPackage(package) { session throws(SessionError) in
                try session.split(ClipID(clip), at: Frames(at), rightID: rightID.map { ClipID($0) })
            }
            print(right)
        }
    }

    struct Move: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move a clip. It overwrites the clips under it at the new place.")
        @OptionGroup var package: PackageArgument
        @Argument var clip: String
        @Option var track: String
        @Option(parsing: .unconditional, help: "The new timeline frame of the first clip frame.") var start: Int

        func run() throws {
            try editPackage(package) { session throws(SessionError) in
                try session.move(ClipID(clip), to: TrackID(track), start: Frames(start))
            }
        }
    }

    struct Trim: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Give a clip a new timeline range.")
        @OptionGroup var package: PackageArgument
        @Argument var clip: String
        @OptionGroup var range: FrameRange

        func run() throws {
            try editPackage(package) { session throws(SessionError) in
                try session.trim(ClipID(clip), to: range.frames)
            }
        }
    }

    struct SetGain: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "gain", abstract: "Set the gain of a clip.")
        @OptionGroup var package: PackageArgument
        @Argument var clip: String
        @Option(parsing: .unconditional, help: "The gain in dB.", transform: parseGain) var db: Gain

        func run() throws {
            try editPackage(package) { session throws(SessionError) in try session.setGain(db, clip: ClipID(clip)) }
        }
    }
}

/// `--from` and `--to`. `Range` traps when the lower bound is above the upper bound, so the
/// parser refuses that first.
struct FrameRange: ParsableArguments {
    @Option(parsing: .unconditional, help: "The first frame.") var from: Int
    @Option(parsing: .unconditional, help: "The frame after the last frame.") var to: Int

    func validate() throws {
        guard from <= to else { throw ValidationError("--from must not be more than --to.") }
    }

    var frames: Range<Frames> { Frames(from)..<Frames(to) }
}
