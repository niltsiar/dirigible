import DirigibleCore

/// The tools that change the export presets of a session (decisions 0011 and 0080). Each one runs the
/// edit of its command: under the lock on the files, and as one undo step in the app. A preset edit is
/// not a batch step.
private let presetName = Param.required(
    "name",
    "The preset name: 1 to 64 characters, with no space at either end and no control character. The name of "
        + "a built-in preset (master or podcast), in any case, is taken.", .string)
private let presetFormat = Param.required("format", "The file format: wav, flac, aac, or mp3.", .string)
private let presetBits = Param<Int?>.optional(
    "bits", "The bit depth of wav and flac: 16 or 24. The default is 24.", .integer())
private let presetBitrate = Param<Int?>.optional(
    "bitrate", "The aac or mp3 bit rate in kbit/s: 64, 96, 128, 160, 192, or 256. The default is 128.", .integer())
private let presetMono = Param.defaulted("mono", "Fold the mix to one channel.", .boolean, false)
private let presetRate = Param<Int?>.optional(
    "rate", "The file rate in Hz: 44100 or 48000. The default is the session rate.", .integer())
private let presetLoudness = Param<String?>.optional(
    "loudness", "Normalize to a loudness target: podcast, speech, ebu, or atsc. The default is none.", .string)
private let presetRename = Param<String?>.optional(
    "rename", "The name of the stored preset that this call renames to name. It keeps its place in the list.",
    .string)

let presetTools = [
    Tool(
        "preset_set",
        "Add an export preset of the session, or change one, as dirigible preset set. A preset has a name and the "
            + "options of one export file; export with presets writes one file for each preset. A name that the "
            + "session stores changes that preset, in its place; with rename, name is the new name of the preset "
            + "that rename gives. Another name adds a preset at the end of the list, and a name that is the name of "
            + "another preset or of a built-in preset, in any case, is refused. The built-in presets cannot change.",
        [presetName, presetFormat, presetBits, presetBitrate, presetMono, presetRate, presetLoudness, presetRename],
        batch: .alone
    ) { a throws(ToolError) in
        let (name, format, bits, bitrate) = (
            try a[presetName], try a[presetFormat], try a[presetBits], try a[presetBitrate]
        )
        let (mono, rate, loudness, rename) = (
            try a[presetMono], try a[presetRate], try a[presetLoudness], try a[presetRename]
        )
        let edit = try PresetWork.set(
            name: name, format: format, bits: bits, bitrate: bitrate, mono: mono, rate: rate, loudness: loudness,
            rename: rename, spelling: .tool)
        return .edit(ripple: false) { session throws(SessionError) in
            try edit(&session)
            return []
        }
    },
    Tool(
        "preset_remove", "Remove an export preset of the session, as dirigible preset remove.", [presetName],
        batch: .alone
    ) { a throws(ToolError) in
        let edit = try PresetWork.remove(name: try a[presetName])
        return .edit(ripple: false) { session throws(SessionError) in
            try edit(&session)
            return []
        }
    },
]
