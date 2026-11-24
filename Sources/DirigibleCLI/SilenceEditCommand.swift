import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP

/// `dirigible silence-edit`: shorten, mute, or mark the silences of a list in one edit (decision
/// 0066).
struct SilenceEditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "silence-edit",
        abstract: "Shorten, mute, or mark each silence of a list in one edit.",
        discussion: """
            Give the ranges of a silences read as --from and --to, and one --action for each, in order. \
            Shorten cuts the middle of the silence on all tracks and closes the gap, so --keep frames \
            stay; the markers move with the cut. Mute lowers the silence by 96 dB on the --track tracks \
            (none is all tracks), with 10 ms ramps inside the silence. Mark adds a marker named \
            "Silence 1", "Silence 2", and so on in the middle. --keep is 500 ms by default. A range with \
            nothing to change (a shorten of --keep frames or less, a mute of 20 ms or less) is skipped: \
            read silences with a --min-length over --keep, so no range is skipped. One line on stdout \
            for each range, in order: "shorten", the range, and the cut; "mute" and the range; "mark", \
            the range, and the marker ID; or "skipped", the range, and the action. Then \
            "removed <n> frames". The frames are those of the session before the edit. Exit 64 when the \
            arguments make no plan: the counts differ, an action is not shorten, mute, or mark, a range \
            is reversed or out of range, two ranges overlap, or --keep is out of range. Exit 1 when a \
            track is unknown. Exit 3 when a shorten that cuts frames meets a take with some segments on the timeline. \
            Exit 2 when the package cannot be read or written, is locked, or has a take that is not \
            finalized.
            """)

    @OptionGroup var package: PackageArgument
    @Option(parsing: .unconditionalSingleValue, help: "The first frame of a range. Give one or more.")
    var from: [Int] = []
    @Option(
        parsing: .unconditionalSingleValue,
        help: "The frame after the last frame of a range. Give one for each --from, in order.")
    var to: [Int] = []
    @Option(
        parsing: .unconditionalSingleValue,
        help: "shorten, mute, or mark. Give one for each --from, in order.")
    var action: [String] = []
    @Option(parsing: .unconditional, help: "The frames that a shorten keeps in each silence. The default is 500 ms.")
    var keep: Int?
    @Option(help: "A track that a mute lowers. Give none for all tracks, or one or more.") var track: [String] = []

    func validate() throws { _ = try work() }

    func run() throws {
        let work = try work()
        let plan = work.plan
        let ripple = RippleNeed { plan.removesFrames(sampleRate: $0.sampleRate) }
        let lines = try editPackage(package, ripple: ripple, touchesClips: false) { session throws(SessionError) in
            work.lines(try session.editSilences(work.plan, muting: EditRules.tracks(track, of: session)))
        }
        print(lines.joined(separator: "\n"))
    }

    func work() throws(ValidationError) -> SilenceEditWork {
        do throws(SilenceEditWork.Refusal) {
            return try SilenceEditWork(from: from, to: to, actions: action, keep: keep)
        } catch {
            throw ValidationError(error.message(prefix: "--"))
        }
    }
}
