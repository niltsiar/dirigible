import ArgumentParser
import DirigibleCore
import DirigibleMCP
import Foundation

extension ClipCommand {
    struct Restore: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Put rendered clips back on their original files, and write the ID of each restored clip.",
            discussion: """
                Each clip goes to the root of its render chain at the frame that it played, with the gain that \
                each render added taken off (decision 0057). The command reads and writes no audio, and the \
                rendered files stay. With no rendered clip in the list, it writes "No rendered clip." and does \
                not save. Exit 1 when a clip is unknown.
                """)

        @OptionGroup var package: PackageArgument
        @Argument(help: "A clip. Give one or more.") var clips: [String] = []

        func validate() throws {
            guard !clips.isEmpty else { throw ValidationError("Give one or more clips.") }
            if let twice = EditRules.firstRepeat(clips) { throw ValidationError("Clip \"\(twice)\" is given twice.") }
        }

        func run() throws {
            let ids = clips.map { ClipID($0) }
            let lines = try editPackage(package, ripple: false, writeUnchanged: false) {
                session throws(SessionError) in
                try restoredClips(ids, in: &session)
            }
            for line in lines { print(line) }
        }
    }
}
