import ArgumentParser
import DirigibleAudio
import DirigibleCore
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
            the value is for the clip frames in the file and the line ends with a tab and "short". It \
            writes nothing and takes no lock. Exit 2 when the package cannot be read or a clip ID is \
            unknown.
            """)

    @OptionGroup var package: PackageArgument
    @Argument(help: "The IDs of the clips to measure. The default is every clip.") var clips: [String] = []

    func run() throws {
        let session = try readPackage(package)
        let all = session.tracks.flatMap(\.clips)
        if let unknown = clips.first(where: { id in !all.contains { $0.id.rawValue == id } }) {
            throw fail(SessionError.unknownClip(ClipID(unknown)).message, code: packageError)
        }
        for clip in all where clips.isEmpty || clips.contains(clip.id.rawValue) {
            let measured: (loudness: Loudness, fault: MediaFault?)
            do {
                measured = try clipLoudness(clip, in: session, package: package.url)
            } catch {
                throw fail("cannot read the audio files: \(error.localizedDescription)", code: packageError)
            }
            let value =
                measured.loudness.withGain(clip.gain).integrated.map { String(format: "%.1f LUFS", $0.value) } ?? "none"
            switch measured.fault {
            case nil: print("\(clip.id)\t\(value)")
            case .short: print("\(clip.id)\t\(value)\tshort")
            case .missing: print("\(clip.id)\tmissing")
            case .unreadable: print("\(clip.id)\tunreadable")
            }
        }
    }
}
