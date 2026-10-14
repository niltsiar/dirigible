import DirigibleCore
import Foundation

private let path = Param<String?>.optional(
    "path", "The absolute path of a Whisper JSON or WebVTT file. Give path or text.", .string)
private let text = Param<String?>.optional(
    "text",
    "The Whisper JSON or WebVTT text, at most \(TranscriptWork.maximumText) bytes. Give it only for a short "
        + "transcript; else give path.", .string)
private let importTrack = Param.required(
    "track", "The track whose clips carry the words. The words follow the clips of this track.", .string)
private let at = Param.defaulted("at", "The timeline frame of second 0 of the transcript.", .integer(), 0)
private let name = Param<String?>.optional(
    "name", "The transcript name. The default is the file name of path, else transcript.", .string)
private let from = Param<Int?>.optional("from", "Only the words that touch this frame on. Give it with to.", .integer())
private let to = Param<Int?>.optional("to", "Only the words before this frame. Give it with from.", .integer())
private let match = Param<String?>.optional(
    "match", "Only the runs of words that say this phrase. Case and punctuation do not count.", .string)
private let wordsTrack = Param<String?>.optional("track", "Only the words over the clips of this track.", .string)
private let limit = Param.defaulted("limit", "The most rows to give, 1 or more.", .integer(), 200)
private let json = Param.defaulted("json", "Give JSON in place of the rows.", .boolean, false)
private let occurrences = Param.required(
    "occurrences", "The word occurrences to cut: the first column of transcript_words. Give all in one call.",
    .strings(minItems: 1))

/// The transcript tools (decision 0055): `dirigible transcript import`, `words`, and `cut`.
let transcriptTools = [
    Tool(
        "transcript_import",
        "Import a Whisper JSON or WebVTT transcript of an export of the whole session; the track is the track whose "
            + "clips carry the words. Give the transcript ID and the count of words. A word with no clip of the track "
            + "under it, or with no time, is skipped. A new import replaces the words of an earlier one in the same "
            + "span.",
        [path, text, importTrack, at, name]
    ) { a throws(ToolError) in
        // Each argument is checked before the source, so a bad argument gets its own text.
        let (track, frame, given) = (TrackID(try a[importTrack]), Frames(try a[at]), try a[name])
        let file: TranscriptFile
        let source: String
        switch (try a[path], try a[text]) {
        case (.some, .some): throw ToolError("Give path or text, not both.")
        case (nil, nil): throw ToolError("Give path or text.")
        case (let location?, nil):
            guard location.hasPrefix("/") else { throw ToolError("The argument \"path\" must be an absolute path.") }
            (file, source) = (try TranscriptWork.file(at: location), URL(filePath: location).lastPathComponent)
        case (nil, let text?):
            guard text.utf8.count <= TranscriptWork.maximumText else { throw ToolError(TranscriptWork.textTooLong) }
            (file, source) = (try TranscriptWork.file(Data(text.utf8), source: "text"), TranscriptWork.defaultName)
        }
        let title = given ?? source
        return .edit { session throws(SessionError) in
            TranscriptWork.importLines(
                try session.importTranscript(file, name: title, track: track, at: frame), cues: file.cues)
        }
    },
    Tool(
        "transcript_words",
        "Give the transcript words over the clips, one row each: occurrence, start, end, track, text. The frames "
            + "are timeline frames. Find a passage with match, or read a range with from and to.",
        [from, to, match, wordsTrack, limit, json], saves: false
    ) { a throws(ToolError) in
        .words(
            try TranscriptQuery(
                from: try a[from], to: try a[to], match: try a[match], track: try a[wordsTrack], limit: try a[limit],
                json: try a[json]))
    },
    Tool(
        "transcript_cut",
        "Cut the words with these occurrences from all tracks, and close each gap, in one edit. Words next to each "
            + "other cut as one range. Give the frames of each cut range.",
        [occurrences]
    ) { a throws(ToolError) in
        let words = try TranscriptWork.occurrences(try a[occurrences])
        return .edit(ripple: true) { session throws(SessionError) in
            TranscriptWork.cutLines(try session.cutWords(words))
        }
    },
]
