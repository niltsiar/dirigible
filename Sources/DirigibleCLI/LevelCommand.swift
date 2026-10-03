import ArgumentParser
import DirigibleAudio
import DirigibleCore
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
            them stay, unless a gain reaches the -20...20 dB limit. Exit 1 when a clip ID is unknown. \
            Exit 2 when the package cannot be read or written, is locked, or has a take that is not \
            finalized.
            """)

    @OptionGroup var package: PackageArgument
    @Argument(help: "The IDs of the clips to level. The default is every clip.") var clips: [String] = []
    @Flag(help: "Give the clips of one track one change.") var perTrack = false

    func run() throws {
        let lines = try editPackage(package) { session throws(SessionError) -> [String] in
            let all = session.tracks.flatMap(\.clips).map(\.id)
            let chosen = clips.isEmpty ? all : clips.map { ClipID($0) }
            if let unknown = chosen.first(where: { session.clip($0) == nil }) { throw .unknownClip(unknown) }
            let set = Set(chosen)
            let (leveled, levels) = autoLevel(
                set, perTrack ? .equallyPerTrack : .eachClip, of: session, in: package.url)
            let lines = all.filter(set.contains).map { id in
                switch levels[id] {
                case .leveled(_, let gain)?: "\(id)\t\(String(format: "%+.1f dB", gain.dB))"
                case .noMeasurement?, nil: "\(id)\tnone"
                case .unreadable?: "\(id)\tunreadable"
                }
            }
            session = leveled
            return lines
        }
        for line in lines { print(line) }
    }
}
