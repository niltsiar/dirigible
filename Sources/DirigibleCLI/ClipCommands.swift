import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

struct ClipCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clip", abstract: "Place, cut, and change clips on tracks.",
        subcommands: [
            Place.self, Clear.self, Split.self, SplitAt.self, SplitStereo.self, Paste.self, PasteClips.self, Nudge.self,
            Remove.self, Denoise.self, Repair.self, Restore.self,
            Move.self, Trim.self,
            SetGain.self, Envelope.self, GainRange.self, Fade.self, Crossfade.self, Heal.self, RippleDelete.self,
            RippleInsert.self, RippleTrim.self,
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
            try editPackage(package, ripple: false) { session throws(SessionError) in
                try session.place(clip, on: TrackID(track))
            }
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
            try editPackage(package, ripple: false) { session throws(SessionError) in
                try session.clear(range.frames, on: track.map { TrackID($0) })
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
            let rights = try editPackage(package, ripple: false) { session throws(SessionError) in
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
        @Option(help: SourceOption.help) var source: String?

        func validate() throws {
            guard !track.isEmpty else { throw ValidationError("Give one or more --track.") }
            guard EditRules.pasteTargets(sources: track, onto: onto) != nil else {
                throw ValidationError("Give one --onto for each --track, or none.")
            }
            try SourceOption.validate(source, package: package, onto: onto)
        }

        func run() throws {
            let sources = track.map { TrackID($0) }
            if let source {
                let work = PasteWork(
                    source: URL(filePath: source), selection: .range(range.frames, tracks: sources),
                    mode: .over(at: Frames(at)), onto: onto)
                return try SourceOption.run(work, package: package)
            }
            // `validate()` checked the targets.
            let targets = (EditRules.pasteTargets(sources: track, onto: onto) ?? []).map { TrackID($0) }
            let pasted = try editPackage(package, ripple: false) { session throws(SessionError) in
                try session.paste(try session.excerpt(of: range.frames, on: sources), at: Frames(at), on: targets)
            }
            for id in pasted { print(id) }
        }
    }

    struct PasteClips: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Copy whole clips with their time and track offsets, and paste them at a frame over the clips "
                + "under them (decision 0038). Write the pasted IDs.")
        @OptionGroup var package: PackageArgument
        @Argument var clips: [String]
        @Option(parsing: .unconditional, help: "The timeline frame of the first copied clip.") var at: Int
        @Option(
            help: "A target track for each track from the first to the last clip. The default is the source tracks.")
        var onto: [String] = []
        @Option(help: SourceOption.help) var source: String?

        func validate() throws { try SourceOption.validate(source, package: package, onto: onto) }

        func run() throws {
            if let source {
                let work = PasteWork(
                    source: URL(filePath: source), selection: .clips(clips.map { ClipID($0) }),
                    mode: .over(at: Frames(at)), onto: onto)
                return try SourceOption.run(work, package: package)
            }
            let pasted = try editPackage(package, ripple: false) { session throws(SessionError) in
                let excerpt = try session.excerpt(of: clips.map { ClipID($0) })
                return try session.paste(excerpt, at: Frames(at), on: EditRules.laneTargets(of: excerpt, onto: onto))
            }
            for id in pasted { print(id) }
        }
    }

    struct Nudge: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move clips by a number of frames and tracks. They overwrite the clips under them.")
        @OptionGroup var package: PackageArgument
        @Argument var clips: [String] = []
        @Option(parsing: .unconditional, help: "The frames to move; negative moves left.") var by: Int
        @Option(parsing: .unconditional, help: "The tracks to move; negative moves up.") var lanes = 0

        func run() throws {
            try editPackage(package, ripple: false) { session throws(SessionError) in
                try session.nudge(clips.map { ClipID($0) }, by: Frames(by), lanes: lanes)
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove clips and leave gaps.")
        @OptionGroup var package: PackageArgument
        @Argument var clips: [String] = []

        func run() throws {
            try editPackage(package, ripple: false) { session throws(SessionError) in
                try session.removeClips(clips.map { ClipID($0) })
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
            let right = try editPackage(package, ripple: false) { session throws(SessionError) in
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
            try editPackage(package, ripple: false) { session throws(SessionError) in
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
            try editPackage(package, ripple: false) { session throws(SessionError) in
                try session.trim(ClipID(clip), to: range.frames)
            }
        }
    }

    struct SetGain: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "gain", abstract: "Set the gain of one or more clips in one edit.")
        @OptionGroup var package: PackageArgument
        @Argument var clips: [String]
        @Option(parsing: .unconditional, help: "The gain in dB.", transform: parseGain) var db: Gain

        func validate() throws {
            if let twice = EditRules.firstRepeat(clips) {
                throw ValidationError("Clip \"\(twice)\" is given twice.")
            }
        }

        func run() throws {
            let gains = Dictionary(uniqueKeysWithValues: clips.map { (ClipID($0), db) })
            try editPackage(package, ripple: false) { session throws(SessionError) in try session.setGains(gains) }
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
            guard EditRules.fadeGiven(fadeIn: fadeIn, fadeOut: fadeOut) else {
                throw ValidationError("Give --in, --out, or both.")
            }
        }

        func run() throws {
            try editPackage(package, ripple: false) { session throws(SessionError) in
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

extension ClipCommand {
    struct Crossfade: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Set the crossfade at the end of a clip and the start of the clip that touches it, in frames "
                + "(decision 0036). 0 removes it.")
        @OptionGroup var package: PackageArgument
        @Option(help: "The left clip of the join.") var clip: String
        @Option(
            parsing: .unconditional, help: "The crossfade length in frames, an even number.",
            transform: parseCrossfadeLength)
        var length: Frames

        func run() throws {
            try editPackage(package, ripple: false) { session throws(SessionError) in
                try session.setCrossfades([ClipID(clip): length])
            }
        }
    }
}

extension ClipCommand {
    struct Heal: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Join the clips that touch and play on in one file at one gain at each frame, the envelope included, "
                + "with no fade at the join. The sound does not change: it undoes a split. Write the ID of each healed clip."
        )
        @OptionGroup var package: PackageArgument
        @Option(help: "A track. The default is all tracks.") var track: [String] = []
        @Option(parsing: .unconditional, help: "Only the joins from this timeline frame. Give it with --to.")
        var from: Int?
        @Option(
            parsing: .unconditional,
            help: "Only the joins to this timeline frame, a join at this frame too. Give it with --from.")
        var to: Int?

        func validate() throws {
            switch (from, to) {
            case (nil, nil): break
            case (let from?, let to?):
                guard EditRules.joinRange(from: from, to: to) != nil else {
                    throw ValidationError("--from must not be more than --to.")
                }
            default: throw ValidationError("Give --from and --to, or neither.")
            }
        }

        func run() throws {
            var range: ClosedRange<Frames>?
            if let from, let to { range = EditRules.joinRange(from: from, to: to) }
            let healed = try editPackage(package, ripple: false) { session throws(SessionError) in
                try session.heal(tracks: track.isEmpty ? nil : track.map { TrackID($0) }, range: range)
            }
            for id in healed { print(id) }
        }
    }
}

/// `EditRules.crossfadeLength` of a number.
func parseCrossfadeLength(_ text: String) throws -> Frames {
    guard let length = Int(text).flatMap(EditRules.crossfadeLength) else {
        throw ValidationError("A crossfade length is an even number of frames, 0 or more.")
    }
    return length
}

/// `--source` of the paste commands (decision 0042): the clips come from another package, and
/// their files copy into this one, at the rate of this session.
enum SourceOption {
    static let help = ArgumentHelp(
        "Another session package to copy from. Its files are copied or converted into this package. Give --onto.",
        valueName: "package")

    static func validate(_ source: String?, package: PackageArgument, onto: [String]) throws {
        guard let source else { return }
        guard !EditRules.sourceNeedsOnto(source: URL(filePath: source), target: package.url, onto: onto) else {
            throw ValidationError("Give --onto with --source of another package.")
        }
    }

    static func run(_ work: PasteWork, package: PackageArgument) throws {
        let pasted = try editPackage(package, ripple: false, refused: refusedPaste) {
            session, lock throws(PasteError) in
            try work.run(&session, lock: lock, package: package.url)
        }
        for id in pasted { print(id) }
    }
}

/// The exit code of a refused paste: 1 for a refused edit, 2 for a source or file fault.
private func refusedPaste(_ error: PasteError) -> ExitCode {
    if case .session(let refusal) = error { return fail(refusal.message, code: editRefused) }
    return fail(error.message, code: packageError)
}

/// `--from` and `--to`, with `EditRules.frameRange`.
struct FrameRange: ParsableArguments {
    @Option(parsing: .unconditional, help: "The first frame.") var from: Int
    @Option(parsing: .unconditional, help: "The frame after the last frame.") var to: Int

    func validate() throws {
        guard EditRules.frameRange(from: from, to: to) != nil else {
            throw ValidationError("--from must not be more than --to.")
        }
    }

    var frames: Range<Frames> { Frames(from)..<Frames(to) }
}
