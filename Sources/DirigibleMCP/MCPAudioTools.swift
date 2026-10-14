import DirigibleAudio
import DirigibleCore
import Foundation

/// The long audio tools of `dirigible mcp`, with progress and cancel (decision 0049). Each one
/// shares its argument rules and its text with its command.
private let loudnessClips = Param<[String]?>.optional(
    "clips", "The IDs of the clips to measure. The default is every clip.", .strings())

private let out = Param.required(
    "out", "The absolute path of the output file, outside each session package. It must not exist, unless replace.",
    .string)
private let renderOut = Param.required(
    "out", "The absolute path of the output file, outside each session package. It must not exist.", .string)
private let bits = Param<Int?>.optional(
    "bits", "The bit depth of WAV and FLAC: 16 or 24. The default is 24.", .integer())
private let bitrate = Param<Int?>.optional(
    "bitrate", "The AAC or MP3 bit rate in kbit/s: 64, 96, 128, 160, 192, or 256. The default is 128.", .integer())
private let mono = Param.defaulted("mono", "Fold the mix to one channel: 0.5 x (L + R).", .boolean, false)
private let rate = Param<Int?>.optional(
    "rate", "The file rate in Hz: 44100 or 48000. The default is the session rate.", .integer())
private let from = Param.defaulted("from", "The first frame.", .integer(), 0)
private let to = Param<Int?>.optional(
    "to", "The frame after the last frame. The default is the session end.", .integer())
private let tracks = Param<[String]?>.optional(
    "track", "The IDs of the tracks to export. The default is every track.", .strings())
private let loudnessTarget = Param<String?>.optional(
    "loudness", "Normalize to a loudness target: podcast (-16), speech (-18), ebu (-23), or atsc (-24) LUFS.", .string)
private let replace = Param.defaulted("replace", "Replace the output file when it exists.", .boolean, false)
private let allowMissing = Param.defaulted(
    "allow_missing", "Export the clips of a missing, short, or unreadable file as silence, with a warning.", .boolean,
    false)

private let chosenClips = Param<[String]?>.optional(
    "clips", "The IDs of the clips to level. The default is every clip.", .strings())
private let perTrack = Param.defaulted(
    "per_track", "Give the clips of one track one change, so the gain differences between them stay.", .boolean,
    false)

private let importFile = Param.required(
    "file", "The absolute path of the audio file: WAV, AIFF, FLAC, MP3, or M4A.", .string)
private let importTrack = Param<String?>.optional(
    "track", "The ID of the track. The default is a new last track with the name and the layout of the file.",
    .string)
private let importAt = Param.defaulted("at", "The timeline frame of the clip start.", .integer(), 0)
private let noLevel = Param.defaulted("no_level", "Keep the gain of the conversion: no auto level.", .boolean, false)

/// The end of the description of a tool that writes a file: a late cancel can leave the file.
private let cancelNote =
    " A cancel stops it, and no file is written; a cancel at the end can be late, so check the output file."

/// The end of the description of a tool that edits the session: a late cancel keeps the change.
private func editCancelNote(_ nothing: String) -> String {
    " A cancel stops it, and \(nothing). A cancel at the end can be late, so read session_info before a retry."
}

/// Refuses a relative `out` first: the option checks resolve a relative path against the working
/// folder of the server, which can differ from the folder of the agent.
private func outPath(_ arguments: Arguments, _ param: Param<String> = out) throws(ToolError) -> String {
    let path = try arguments[param]
    guard path.hasPrefix("/") else { throw ToolError("The argument \"out\" must be an absolute path.") }
    return path
}

let audioTools = [
    Tool(
        "loudness",
        "Show the integrated loudness of each clip, the text of dirigible loudness: one line for each clip, the "
            + "clip ID, a tab, and the BS.1770 loudness with the clip gain, \"none\", \"missing\", or \"unreadable\". "
            + "It writes nothing. A cancel stops the measure.",
        [loudnessClips], saves: false
    ) { a throws(ToolError) in .loudness(clips: try a[loudnessClips] ?? []) }.hinted(.readOnly),
    Tool(
        "export",
        "Export the session mix to WAV, AAC (.m4a), MP3, or FLAC, as dirigible export. The extension of out gives "
            + "the format. The text is the loudness line with a loudness target, then the warning lines, or OK. A "
            + "file in the range that is missing, short, or unreadable refuses the export, unless allow_missing."
            + cancelNote,
        [out, bits, bitrate, mono, rate, from, to, tracks, loudnessTarget, replace, allowMissing], saves: false
    ) { a throws(ToolError) in
        // The type of each argument first, then the path, then the option rules.
        let (depth, kbits, folds, hertz, target) = (
            try a[bits], try a[bitrate], try a[mono], try a[rate], try a[loudnessTarget]
        )
        let (first, end, ids, replaces, allows) = (
            try a[from], try a[to], try a[tracks] ?? [], try a[replace], try a[allowMissing]
        )
        let path = try outPath(a)
        let options = try ExportText.options(
            out: path, bits: depth, bitrate: kbits, mono: folds, rate: hertz, loudness: target, spelling: .tool)
        return .export(
            ExportWork(
                out: path, options: options, from: first, to: end, tracks: ids.map { TrackID($0) },
                replace: replaces, allowMissing: allows))
    },
    Tool(
        "render",
        "Render the session mix to a 32-bit float stereo CAF file at the session rate, as dirigible render. A "
            + "missing or short file renders as silence, with a warning line. The text is the warning lines, or OK."
            + cancelNote,
        [renderOut, from, to], saves: false
    ) { a throws(ToolError) in
        let (first, end) = (try a[from], try a[to])
        let path = try outPath(a, renderOut)
        try ExportText.checkOutsidePackages(URL(filePath: path))
        return .export(
            ExportWork(
                out: path, options: .render, from: first, to: end, tracks: [], replace: false, allowMissing: true))
    },
    Tool(
        "level",
        "Set the gain of each clip to the loudness target of its track layout, as dirigible level: -16 LUFS for a "
            + "stereo track and -19 LUFS for a mono track, within -20...20 dB. The text is one line for each clip, "
            + "the clip ID, a tab, and the new gain, \"none\", or \"unreadable\", then the report line. A level that "
            + "changes no gain writes nothing." + editCancelNote("no gain changes"),
        [chosenClips, perTrack]
    ) { a throws(ToolError) in .level(LevelWork(clips: try a[chosenClips] ?? [], perTrack: try a[perTrack])) },
    Tool(
        "import",
        "Import an audio file into a track, as dirigible import: the file becomes a 24-bit WAV at the session rate in "
            + "Clips/, and a clip at the frame at that overwrites the clips under it, with the gain of Auto Level "
            + "unless no_level. The text is the clip ID." + editCancelNote("no clip is added"),
        [importFile, importTrack, importAt, noLevel]
    ) { a throws(ToolError) in
        let (path, track, start, keeps) = (try a[importFile], try a[importTrack], try a[importAt], try a[noLevel])
        guard path.hasPrefix("/") else { throw ToolError("The argument \"file\" must be an absolute path.") }
        return .importFile(ImportWork(file: path, track: track, at: start, level: !keeps))
    },
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
