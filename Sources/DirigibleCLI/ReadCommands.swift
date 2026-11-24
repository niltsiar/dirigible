import ArgumentParser
import DirigibleCore
import DirigibleMCP
import Foundation

/// The options of the range reads `silences` and `meter`.
struct ReadRange: ParsableArguments {
    @Option(parsing: .unconditional, help: "The first frame of the range.") var from = 0
    @Option(parsing: .unconditional, help: "The frame after the range. The default and the most is the session end.")
    var to: Int?
}

/// The track option of the three reads.
struct ReadTracks: ParsableArguments {
    @Option(help: "The ID of a track to read. Repeat it for more tracks. The default is every track.")
    var track: [String] = []
}

/// Reads `package` with `work`: the warning lines on stderr, the result lines on stdout. A bad
/// value for the session exits 64; an unknown track, a file that refuses the read, or a package
/// that cannot be read exits 2. Control-C exits as the default action does. An archived package
/// unarchives first (`readForSamples`).
func runRead(_ work: ReadWork, package: PackageArgument) throws {
    let session = try readForSamples(package)
    let interrupt = cancelOnInterrupt()
    defer { interrupt.source.cancel() }
    let output: ReadOutput
    do throws(ReadFailure) {
        output = try work.read(session, package: package.url, isCancelled: interrupt.isCancelled)
    } catch {
        switch error {
        case .usage(let text): throw ValidationError(text)
        case .refused(let text): throw fail(text, code: packageError)
        case .cancelled: throw ExitCode(128 + SIGINT)
        }
    }
    warn(output.stderr)
    for line in output.stdout { print(line) }
}

/// The parse of a read: a refusal is a usage error.
func readWork(_ parsed: Result<ReadWork, ToolError>) throws(ValidationError) -> ReadWork {
    switch parsed {
    case .success(let work): return work
    case .failure(let error): throw ValidationError(error.message)
    }
}

/// `dirigible silences` (decision 0062).
struct SilencesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "silences",
        abstract: "List the silences of a range of the mix.",
        discussion: """
            A silence is a run of 50 ms windows of the mix of the tracks at or under --threshold dBFS, \
            of --min-length frames or more, with mute and solo ignored. The windows start at multiples \
            of 50 ms from frame 0. One line for each silence that meets the range, with its whole \
            extent: the first frame, a tab, and the frame after it; at most 1000 lines, then a line \
            with the count of the others. "No silence." when none. A silence that goes on more than \
            60 s past the range stops there, with a warning line on stderr. It writes nothing and takes \
            no lock. Exit 64 for a bad value or a --from at or after the session end. Exit 2 when the \
            package cannot be read, a track is unknown, or a file of the read is missing, short, or \
            unreadable: its clips would read as silence.
            """)

    @OptionGroup var package: PackageArgument
    @OptionGroup var range: ReadRange
    @OptionGroup var tracks: ReadTracks
    @Option(parsing: .unconditional, help: "The silence level in dBFS, under 0. The default is -40.")
    var threshold: Double?
    @Option(parsing: .unconditional, help: "The shortest silence in frames. The default is 500 ms.")
    var minLength: Int?

    func work() throws(ValidationError) -> ReadWork {
        try readWork(
            ReadWork.silences(
                from: range.from, to: range.to, tracks: tracks.track, threshold: threshold, minLength: minLength,
                spelling: .cli))
    }

    func validate() throws { _ = try work() }

    func run() throws { try runRead(try work(), package: package) }
}

/// `dirigible nearest-pause` (decision 0062).
struct NearestPauseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nearest-pause",
        abstract: "Find the best cut point near a frame.",
        discussion: """
            The pause is the silence of the rule of dirigible silences, with --min-length, that meets \
            --at minus --window to --at plus --window and is nearest to --at; a tie takes the earlier \
            one. One line: "pause", the first frame, the frame after it, and the cut, with tabs. The \
            cut is the middle frame of the silence, or the frame of the search range nearest to it. \
            With no silence: "no pause", the middle frame of the quietest 50 ms window, and its level \
            in dBFS (-inf dBFS for digital silence). A silence that goes on more than 60 s past the \
            search range stops there, with a warning line on stderr. It writes nothing and takes no \
            lock. Exit 64 for a bad value or an --at at or after the session end. Exit 2 when the \
            package cannot be read, a track is unknown, or a file of the read is missing, short, or \
            unreadable.
            """)

    @OptionGroup var package: PackageArgument
    @Option(parsing: .unconditional, help: "The frame to find a pause near.") var at: Int
    @Option(
        parsing: .unconditional, help: "The search reaches this many frames before and after --at. The default is 2 s.")
    var window: Int?
    @OptionGroup var tracks: ReadTracks
    @Option(parsing: .unconditional, help: "The silence level in dBFS, under 0. The default is -40.")
    var threshold: Double?
    @Option(parsing: .unconditional, help: "The shortest pause in frames. The default is 200 ms.")
    var minLength: Int?

    func work() throws(ValidationError) -> ReadWork {
        try readWork(
            ReadWork.nearestPause(
                at: at, window: window, tracks: tracks.track, threshold: threshold, minLength: minLength,
                spelling: .cli))
    }

    func validate() throws { _ = try work() }

    func run() throws { try runRead(try work(), package: package) }
}

/// `dirigible meter` (decision 0062).
struct MeterCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meter",
        abstract: "Measure the loudness and the peaks of a range of the heard stereo mix.",
        discussion: """
            It measures the heard stereo mix of the range, as a stereo export: mute and solo count, and \
            a mono track goes to both channels. One line: the integrated loudness (BS.1770), the \
            loudness range (EBU Tech 3342; none under 2 min), the max momentary and short-term \
            loudness, the true peak, and the sample peak, each with one decimal or "none". With \
            --step, then one line for each step from the 50 ms window of --from: its first frame, the \
            RMS level, and the peak, in dBFS (-inf dBFS for digital silence). A missing, short, or unreadable file reads as silence. The warning \
            lines of a stereo export go to stderr: the files that read as silence, and the muted or not \
            soloed tracks. It writes nothing and takes no lock. Exit 64 for a bad value, a \
            --from at or after the session end, a --step that is not a multiple of the 50 ms window, \
            or more than 1000 steps. Exit 2 when the package cannot be read or a track is unknown.
            """)

    @OptionGroup var package: PackageArgument
    @OptionGroup var range: ReadRange
    @OptionGroup var tracks: ReadTracks
    @Option(parsing: .unconditional, help: "Also give the RMS level and the peak of each step of this many frames.")
    var step: Int?

    func work() throws(ValidationError) -> ReadWork {
        try readWork(ReadWork.meter(from: range.from, to: range.to, tracks: tracks.track, step: step, spelling: .cli))
    }

    func validate() throws { _ = try work() }

    func run() throws { try runRead(try work(), package: package) }
}
