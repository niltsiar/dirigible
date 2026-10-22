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

private let duckSpeech = Param<[String]?>.optional(
    "speech", "The IDs of the speech tracks. The default is the tracks with the dialogue role.", .strings())
private let duckMusic = Param<[String]?>.optional(
    "music", "The IDs of the tracks to duck. The default is the tracks with the music role.", .strings())
private let duckFrom = Param<Int?>.optional("from", "The first timeline frame of the scope, with to.", .integer())
private let duckTo = Param<Int?>.optional("to", "The timeline frame after the scope, with from.", .integer())
private let duckDepth = Param<Gain?>.optional(
    "depth", "The gain of the music under speech in dB, under 0. The default is -16.", .gain)
private let duckAttack = Param<Int?>.optional(
    "attack", "The ramp down before speech in frames. The default is 1 s.", .integer())
private let duckRelease = Param<Int?>.optional(
    "release", "The ramp up after speech in frames. The default is 1 s.", .integer())
private let duckThreshold = Param<Gain?>.optional(
    "threshold", "The speech level in dBFS, under 0. The default is -40.", .gain)
private let duckHold = Param<Int?>.optional(
    "hold",
    "The hold in frames. The music comes up after a pause of at least the larger of the hold and attack plus release. The default is 2 s.",
    .integer())

private let importFile = Param.required(
    "file", "The absolute path of the audio file: WAV, AIFF, FLAC, MP3, or M4A.", .string)
private let importTrack = Param<String?>.optional(
    "track", "The ID of the track. The default is a new last track with the name and the layout of the file.",
    .string)
private let importAt = Param.defaulted("at", "The timeline frame of the clip start.", .integer(), 0)
private let noLevel = Param.defaulted("no_level", "Keep the gain of the conversion: no auto level.", .boolean, false)
private let importID = Param<String?>.optional(
    "id", "The clip ID. The default is the file name with no extension.", .string)
private let importOffset = Param.defaulted(
    "offset", "The first clip frame in the made WAV, at the session rate.", .integer(), 0)
private let importLength = Param<Int?>.optional(
    "length",
    "The clip length in frames of the made WAV, at the session rate. A longer length stops at the end of the WAV. "
        + "The default is the rest of the WAV.", .integer())
private let importGain = Param<Gain?>.optional(
    "db",
    "The clip gain in dB, relative to the level of the file: 0 keeps that level. No auto level runs. The "
        + "default is the gain of Auto Level.", .gain)
private let importFadeIn = Param.defaulted("fade_in", "The fade-in length in frames.", .integer(), 0)
private let importFadeOut = Param.defaulted("fade_out", "The fade-out length in frames.", .integer(), 0)

/// The end of the description of a tool that writes a file: a late cancel can leave the file.
private let cancelNote =
    " A cancel stops it, and no file is written; a cancel at the end can be late, so check the output file."

/// The end of the description of a tool that edits the session: a late cancel keeps the change.
private func editCancelNote(_ nothing: String) -> String {
    " A cancel stops it, and \(nothing). A cancel at the end can be late, so read session_info before a retry."
}

/// Refuses a relative `out` first: the option checks resolve a relative path against the working
/// folder of the server, which can differ from the folder of the agent.
func outPath(_ arguments: Arguments, _ param: Param<String>) throws(ToolError) -> String {
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
        let path = try outPath(a, out)
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
        "duck",
        "Lower the music under the speech, as dirigible duck: it writes gain envelope points. The speech is the mix of the "
            + "speech tracks over the threshold, with mute and solo ignored. A track with no role is in a list only "
            + "when named. The duck replaces the points inside the clip window, or inside from and to, of each clip "
            + "that speech reaches, and keeps the other points and clips. The text is the lines of the command (speech "
            + "runs, ducked clips, unchanged clips, kept clips, speech files that did not read), then the report line. The scope ends at the session end. A from at or "
            + "after the session end, or no speech over the threshold, changes nothing."
            + editCancelNote("no envelope changes"),
        [duckSpeech, duckMusic, duckFrom, duckTo, duckDepth, duckAttack, duckRelease, duckThreshold, duckHold]
    ) { a throws(ToolError) in
        let (speech, music, first, end) = (
            try a[duckSpeech] ?? [], try a[duckMusic] ?? [], try a[duckFrom], try a[duckTo]
        )
        let (depth, attack, release) = (try a[duckDepth], try a[duckAttack], try a[duckRelease])
        let (threshold, hold) = (try a[duckThreshold], try a[duckHold])
        switch DuckWork.parse(
            speech: speech, music: music, from: first, to: end, depth: depth?.dB, attack: attack, release: release,
            threshold: threshold?.dB, hold: hold)
        {
        case .success(let work): return .duck(work)
        case .failure(let error): throw error
        }
    },
    Tool(
        "import",
        "Import an audio file into a track, as dirigible import: the file becomes a 24-bit WAV at the session rate in "
            + "Clips/, and a clip at the frame at that overwrites the clips under it, with the gain of Auto Level "
            + "unless db or no_level. offset and length are frames of the made WAV, so one call takes a part of the "
            + "file with its gain and fades. The text is the clip ID." + editCancelNote("no clip is added"),
        [
            importFile, importTrack, importAt, noLevel, importID, importOffset, importLength, importGain, importFadeIn,
            importFadeOut,
        ]
    ) { a throws(ToolError) in
        let (path, track, start, keeps) = (try a[importFile], try a[importTrack], try a[importAt], try a[noLevel])
        let (id, first, count, gain) = (try a[importID], try a[importOffset], try a[importLength], try a[importGain])
        let (fadeIn, fadeOut) = (try a[importFadeIn], try a[importFadeOut])
        guard path.hasPrefix("/") else { throw ToolError("The argument \"file\" must be an absolute path.") }
        guard let range = EditRules.importRange(offset: first, length: count) else {
            throw ToolError("offset is a frame in 0...2^40, and length is a length in 1...2^40.")
        }
        guard let fades = Fades(fadeIn: Frames(fadeIn), fadeOut: Frames(fadeOut)) else {
            throw ToolError("fade_in and fade_out are lengths in 0...2^40.")
        }
        let target = ImportTarget(
            track: track.map { TrackID($0) }, start: Frames(start), clip: id.map { ClipID($0) },
            offset: range.offset, length: range.length, gain: gain, fades: fades)
        return .importFile(ImportWork(file: path, target: target, level: !keeps))
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
