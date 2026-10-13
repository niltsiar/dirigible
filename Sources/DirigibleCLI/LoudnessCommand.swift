import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

/// `dirigible loudness`: the integrated loudness of each clip (run 8a, decision 0008).
struct LoudnessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "loudness",
        abstract: "Show the integrated loudness of each clip of a session package.",
        discussion: """
            One line for each clip, track by track in timeline order: the clip ID, a tab, and the \
            BS.1770 loudness with the clip gain (for example "-16.0 LUFS"), "none" when no block passes \
            the gates, "missing", or "unreadable". When the file has fewer frames than the session says, \
            the value is for the clip frames in the file and the line ends with a tab and "short". The \
            value has the clip gain, but no fade and no track gain. It writes nothing and takes no \
            lock. Exit 2 when the package cannot be read or a clip ID is unknown.
            """)

    @OptionGroup var package: PackageArgument
    @Argument(help: "The IDs of the clips to measure. The default is every clip.") var clips: [String] = []

    func run() throws {
        let session = try readPackage(package)
        let chosen: [Clip]
        do throws(SessionError) { chosen = try loudnessClips(clips, in: session) } catch {
            throw fail(error.message, code: packageError)
        }
        for clip in chosen {
            do {
                print(loudnessLine(clip, try clipLoudness(clip, in: session, package: package.url)))
            } catch {
                throw fail(audioReadMessage(error), code: packageError)
            }
        }
    }
}
