import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

extension ClipCommand {
    struct Replace: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Copy a range of tracks and replace the range --at to --until with it (decision 0053). The range goes "
                + "on every track, and the later audio on every track moves by the copy length minus the range "
                + "length. --at must be less than --until, else the command exits 64. Write the pasted IDs.")
        @OptionGroup var paste: RangePaste

        func run() throws { try paste.run(.replace(paste.target)) }
    }

    struct Fill: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Copy a range of tracks and paste it again and again from --at, with butt joins, and cut the last "
                + "copy at --until (decision 0053). Nothing moves. --at must be less than --until, else the command "
                + "exits 64. Write the pasted IDs.")
        @OptionGroup var paste: RangePaste

        func run() throws { try paste.run(.fill(paste.target)) }
    }
}

/// The arguments of `clip replace` and `clip fill`: the copied range of tracks, the target range,
/// the target tracks, and the source package.
struct RangePaste: ParsableArguments {
    @OptionGroup var package: PackageArgument
    @OptionGroup var range: FrameRange
    @Option(help: "A source track. Give one or more.") var track: [String] = []
    @Option(parsing: .unconditional, help: "The first frame of the target range.") var at: Int
    @Option(parsing: .unconditional, help: "The frame after the last frame of the target range.") var until: Int
    @Option(help: "A target track for each --track, in order. The default is the source tracks.")
    var onto: [String] = []
    @Option(help: SourceOption.help) var source: String?

    func validate() throws {
        guard !track.isEmpty else { throw ValidationError("Give one or more --track.") }
        guard EditRules.pasteTargets(sources: track, onto: onto) != nil else {
            throw ValidationError("Give one --onto for each --track, or none.")
        }
        guard EditRules.targetRange(at: at, until: until) != nil else {
            throw ValidationError("--at must be less than --until.")
        }
        try SourceOption.validate(source, package: package, onto: onto)
    }

    var target: Range<Frames> { Frames(at)..<Frames(until) }

    func run(_ mode: PasteMode) throws {
        let sources = track.map { TrackID($0) }
        if let source {
            let work = PasteWork(
                source: URL(filePath: source), selection: .range(range.frames, tracks: sources), mode: mode, onto: onto)
            return try SourceOption.run(work, package: package)
        }
        // `validate()` checked the targets.
        let targets = (EditRules.pasteTargets(sources: track, onto: onto) ?? []).map { TrackID($0) }
        let pasted = try editPackage(package, ripple: RippleNeed { _ in mode.ripples }) {
            session throws(SessionError) in
            try session.paste(try session.excerpt(of: range.frames, on: sources), mode: mode, on: targets)
        }
        for id in pasted { print(id) }
    }
}
