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
            them stay, unless a gain reaches the -20...20 dB limit. Then one report line on stderr: \
            the count of changed clips, of changed clips at the limit, and of clips with no level, or \
            "No change: the clips are at the target level." A level that changes no gain does not \
            write session.xml. Exit 1 when a clip ID is unknown. \
            Exit 2 when the package cannot be read or written, is locked, or has a take that is not \
            finalized.
            """)

    @OptionGroup var package: PackageArgument
    @Argument(help: "The IDs of the clips to level. The default is every clip.") var clips: [String] = []
    @Flag(help: "Give the clips of one track one change.") var perTrack = false

    func run() throws {
        let (lines, report) = try editPackage(package, writeUnchanged: false) {
            session throws(SessionError) -> ([String], LevelReport) in
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
            let report = LevelReport(levels, before: session)
            session = leveled
            return (lines, report)
        }
        for line in lines { print(line) }
        try? FileHandle.standardError.write(contentsOf: Data((Self.text(of: report) + "\n").utf8))
    }

    /// The report line: the banner text of the app without its head and the track volume sentence.
    static func text(of report: LevelReport) -> String {
        guard report.changed > 0 || report.atLimit > 0 || report.unmeasured > 0 else {
            return "No change: the clips are at the target level."
        }
        var text = "Clips changed: \(report.changed)."
        if report.atLimit > 0 { text += " Clips at the 20 dB limit: \(report.atLimit). Check that they have speech." }
        if report.unmeasured > 0 {
            text += " Clips with no level to measure: \(report.unmeasured). They keep their gain."
        }
        return text
    }
}
