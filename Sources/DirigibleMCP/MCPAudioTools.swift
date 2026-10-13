import DirigibleAudio
import DirigibleCore
import Foundation

/// The long audio tools of `dirigible mcp`, with progress and cancel (decision 0049). Each one
/// shares its argument rules and its text with its command.
private let loudnessClips = Param<[String]?>.optional(
    "clips", "The IDs of the clips to measure. The default is every clip.", .strings())

let audioTools = [
    Tool(
        "loudness",
        "Show the integrated loudness of each clip, the text of dirigible loudness: one line for each clip, the "
            + "clip ID, a tab, and the BS.1770 loudness with the clip gain, \"none\", \"missing\", or \"unreadable\". "
            + "It writes nothing. A cancel stops the measure.",
        [loudnessClips], saves: false
    ) { a throws(ToolError) in .loudness(clips: try a[loudnessClips] ?? []) }
]

/// The clips of `dirigible loudness` and the `loudness` tool: each clip, track by track in
/// timeline order, or only the clips of `ids`.
package func loudnessClips(_ ids: [String], in session: Session) throws(SessionError) -> [Clip] {
    let all = session.tracks.flatMap(\.clips)
    if let unknown = ids.first(where: { id in !all.contains { $0.id.rawValue == id } }) {
        throw .unknownClip(ClipID(unknown))
    }
    return all.filter { ids.isEmpty || ids.contains($0.id.rawValue) }
}

/// The line of one clip of `dirigible loudness`, with no newline.
package func loudnessLine(_ clip: Clip, _ measured: (loudness: Loudness, fault: MediaFault?)) -> String {
    let value =
        measured.loudness.withGain(clip.gain).integrated.map { String(format: "%.1f LUFS", $0.value) } ?? "none"
    return switch measured.fault {
    case nil: "\(clip.id)\t\(value)"
    case .short: "\(clip.id)\t\(value)\tshort"
    case .missing: "\(clip.id)\tmissing"
    case .unreadable: "\(clip.id)\tunreadable"
    }
}

/// The error text of a loudness measure that cannot read the audio files.
package func audioReadMessage(_ error: any Error) -> String {
    "cannot read the audio files: \(error.localizedDescription)"
}

/// The text of a cancelled call. The client gets no answer, so no one reads it.
let cancelledMessage = "The call was cancelled."

/// `loudness` on the files: no lock, as `dirigible loudness`.
func loudness(_ package: URL, path: String, ids: [String], control: CallControl) throws(ToolError) -> String {
    let session: Session
    let clips: [Clip]
    do throws(SessionFileError) { session = try Session(contentsOf: package) } catch {
        throw ToolError(error.message(package: path))
    }
    do throws(SessionError) { clips = try loudnessClips(ids, in: session) } catch { throw ToolError(error.message) }
    do throws(POSIXError) {
        let measured = try clipsLoudness(
            clips, in: session, package: package, progress: control.report, isCancelled: control.isCancelled)
        return zip(clips, measured).map(loudnessLine).joined(separator: "\n")
    } catch {
        throw ToolError(error.code == .ECANCELED ? cancelledMessage : audioReadMessage(error))
    }
}
