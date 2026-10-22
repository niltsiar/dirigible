import ArgumentParser
import DirigibleCore
import DirigibleMCP
import Foundation

/// `dirigible duck`: the music goes down under the speech (decision 0060).
struct DuckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "duck",
        abstract: "Lower the music under the speech with gain envelope points.",
        discussion: """
            The speech tracks are the tracks of --speech, else the tracks with the dialogue role. The \
            tracks to duck are the tracks of --music, else the tracks with the music role. A track \
            with no role is in a list only when you name it. The speech is the mix of the speech \
            tracks in 50 ms windows over --threshold dBFS, with mute and solo ignored; runs with a \
            gap under the hold, or under attack plus release, join. The duck replaces the envelope \
            points inside the clip window, or inside --from and --to, of each clip that a run reaches, \
            and keeps the other points and clips. Lines on stdout: "speech", the first frame, and the \
            frame after the end of each run; "ducked" and the ID of each changed clip; "kept" and the \
            ID of each clip that no run reaches. Then one report line on stderr. Exit 1 when no track \
            is a speech track or a track to duck, a track is unknown or in both lists, or no speech \
            is over the threshold: then nothing changes. Exit 2 when the package cannot be read or \
            written, is locked, or has a take that is not finalized.
            """)

    @OptionGroup var package: PackageArgument
    @Option(help: "A speech track ID. Repeat it for more tracks.") var speech: [String] = []
    @Option(help: "The ID of a track to duck. Repeat it for more tracks.") var music: [String] = []
    @Option(help: "The first timeline frame of the scope, with --to.") var from: Int?
    @Option(help: "The timeline frame after the scope, with --from.") var to: Int?
    @Option(help: "The gain of the music under speech in dB, under 0. The default is -16.") var depth: Double?
    @Option(help: "The ramp down before speech in frames. The default is 1 s.") var attack: Int?
    @Option(help: "The ramp up after speech in frames. The default is 1 s.") var release: Int?
    @Option(help: "The speech level in dBFS, under 0. The default is -40.") var threshold: Double?
    @Option(help: "The shortest pause in frames that lets the music come up. The default is 2 s.") var hold: Int?

    func work() throws(ValidationError) -> DuckWork {
        switch DuckWork.parse(
            speech: speech, music: music, from: from, to: to, depth: depth, attack: attack, release: release,
            threshold: threshold, hold: hold)
        {
        case .success(let work): return work
        case .failure(let error): throw ValidationError(error.message)
        }
    }

    func validate() throws { _ = try work() }

    func run() throws {
        let work = try work()
        let (lines, report) = try editPackage(package, ripple: false, writeUnchanged: false, refused: failure) {
            session, _ throws(DuckFailure) in
            try work.run(&session, package: package.url)
        }
        for line in lines { print(line) }
        try? FileHandle.standardError.write(contentsOf: Data((report + "\n").utf8))
    }

    /// The error line and the exit code of a duck that changes nothing. The command has no cancel
    /// flag, so only the tool gets `.cancelled`.
    func failure(_ error: DuckFailure) -> ExitCode {
        switch error {
        case .session: fail(error.message, code: editRefused)
        case .audio, .cancelled: fail(error.message, code: packageError)
        }
    }
}
