import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

/// `dirigible level`: the auto level of the app (run 8b, decisions 0008 and 0031).
struct LevelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "level",
        abstract: "Set the gain of each clip to the loudness target of its track layout.",
        discussion: """
            The target is -16 LUFS for a stereo track and -19 LUFS for a mono track. The gain is \
            clamped to -20...20 dB. One line for each clip, track by track in timeline order: the clip \
            ID, a tab, and the new gain (for example "+7.0 dB"), "none" when no block passes the gates, \
            or "unreadable" when the file is missing or does not read. Such a clip keeps its gain. \
            With --per-track, the clips of one track get one change, so the gain differences between \
            them stay, unless a gain reaches the -20...20 dB limit. Then one report line on stderr: \
            the count of changed clips, of clips at the limit, and of clips with no level, or \
            "No change: the clips are at the target level." A level that changes no gain does not \
            write session.xml. Exit 1 when a clip ID is unknown. \
            Exit 2 when the package cannot be read or written, is locked, or has a take that is not \
            finalized.
            """)

    @OptionGroup var package: PackageArgument
    @Argument(help: "The IDs of the clips to level. The default is every clip.") var clips: [String] = []
    @Flag(help: "Give the clips of one track one change.") var perTrack = false

    func run() throws {
        let work = LevelWork(clips: clips, perTrack: perTrack)
        let result = try editPackage(package, writeUnchanged: false) { session throws(SessionError) in
            try work.run(&session, package: package.url)
        }
        // With no cancel flag, the level always gives its lines.
        guard let (lines, report) = result else { return }
        for line in lines { print(line) }
        try? FileHandle.standardError.write(contentsOf: Data((report + "\n").utf8))
    }
}
