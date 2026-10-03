import ArgumentParser
import DirigibleCore

struct ClipCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clip", abstract: "Place, cut, and change clips on tracks.",
        subcommands: [
            Place.self, Clear.self, Split.self, SplitAt.self, Paste.self, Nudge.self, Move.self, Trim.self,
            SetGain.self, Fade.self,
        ])

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
        static let configuration = CommandConfiguration(
            abstract: "Remove the frames in a range on each track and leave a gap. One save for all tracks.")
        @OptionGroup var package: PackageArgument
        @Option(help: "A track. Give one or more.") var track: [String] = []
        @OptionGroup var range: FrameRange

        func validate() throws {
            guard !track.isEmpty else { throw ValidationError("Give one or more --track.") }
        }

        func run() throws {
            try editPackage(package) { session throws(SessionError) in
                for track in track { try session.clear(range.frames, on: TrackID(track)) }
            }
        }
    }

    struct SplitAt: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Split each clip that holds a frame inside it, and write the IDs of the right parts.")
        @OptionGroup var package: PackageArgument
        @Option(help: "A track. Give one or more.") var track: [String] = []
        @Option(parsing: .unconditionalSingleValue, help: "A timeline frame. Give one or more.") var at: [Int] = []

        func validate() throws {
            guard !track.isEmpty, !at.isEmpty else { throw ValidationError("Give one or more --track and --at.") }
        }

        func run() throws {
            let rights = try editPackage(package) { session throws(SessionError) in
                try session.splitClips(at: at.map { Frames($0) }, on: track.map { TrackID($0) })
            }
            for id in rights { print(id) }
        }
    }

    struct Paste: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copy a range of tracks and paste it at a frame over the clips there. Write the pasted IDs.")
        @OptionGroup var package: PackageArgument
        @OptionGroup var range: FrameRange
        @Option(help: "A source track. Give one or more.") var track: [String] = []
        @Option(parsing: .unconditional, help: "The timeline frame of the paste.") var at: Int
        @Option(help: "A target track for each --track, in order. The default is the source tracks.")
        var onto: [String] = []

        func validate() throws {
            guard !track.isEmpty else { throw ValidationError("Give one or more --track.") }
            guard onto.isEmpty || onto.count == track.count else {
                throw ValidationError("Give one --onto for each --track, or none.")
            }
        }

        func run() throws {
            let sources = track.map { TrackID($0) }
            let targets = onto.isEmpty ? sources : onto.map { TrackID($0) }
            let pasted = try editPackage(package) { session throws(SessionError) in
                try session.paste(try session.excerpt(of: range.frames, on: sources), at: Frames(at), on: targets)
            }
            for id in pasted { print(id) }
        }
    }

    struct Nudge: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move clips by a number of frames on their tracks. They overwrite the clips under them.")
        @OptionGroup var package: PackageArgument
        @Argument var clips: [String] = []
        @Option(parsing: .unconditional, help: "The frames to move; negative moves left.") var by: Int

        func run() throws {
            try editPackage(package) { session throws(SessionError) in
                try session.nudge(clips.map { ClipID($0) }, by: Frames(by))
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

extension ClipCommand {
    struct Fade: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set the fade-in or the fade-out of a clip in frames (decision 0035). 0 removes a fade.")
        @OptionGroup var package: PackageArgument
        @Option var clip: String
        @Option(
            name: .customLong("in"), parsing: .unconditional,
            help: "The fade-in length in frames. The default is the current value.")
        var fadeIn: Int?
        @Option(
            name: .customLong("out"), parsing: .unconditional,
            help: "The fade-out length in frames. The default is the current value.")
        var fadeOut: Int?

        func validate() throws {
            guard fadeIn != nil || fadeOut != nil else { throw ValidationError("Give --in, --out, or both.") }
        }

        func run() throws {
            try editPackage(package) { session throws(SessionError) in
                let id = ClipID(clip)
                guard let current = session.clip(id)?.clip.fades else { throw .unknownClip(id) }
                let fadeIn = fadeIn.map { Frames($0) } ?? current.fadeIn
                let fadeOut = fadeOut.map { Frames($0) } ?? current.fadeOut
                guard let fades = Fades(fadeIn: fadeIn, fadeOut: fadeOut) else { throw .frameOutOfRange }
                try session.setFades([id: fades])
            }
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
