import DirigibleCore
import Foundation

private let path = Param<String?>.optional(
    "path", "The absolute path of a Whisper JSON, WebVTT, or SRT file. Give path or text.", .string)
private let text = Param<String?>.optional(
    "text",
    "The Whisper JSON, WebVTT, or SRT text, at most \(TranscriptWork.maximumText) bytes. Give it only for a short "
        + "transcript; else give path.", .string)
private let importTrack = Param.required(
    "track", "The track whose clips carry the words. The words follow the clips of this track.", .string)
private let at = Param.defaulted(
    "at", "The frame of second 0 of the transcript: a timeline frame, or with take a take frame.", .integer(), 0)
private let take = Param<Int?>.optional(
    "take",
    "The take number, 1 or more, when the transcript is of one take. Time 0 is then the record start of that take, "
        + "and the words follow the audio of the take after each edit. Leave it out for a transcript of an export "
        + "of the session.", .integer(minimum: 1))
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

private let transcribeTrack = Param.required("track", "The track whose clips to transcribe.", .string)
private let language = Param.defaulted(
    "language", "auto, or a whisper language code, for example es. auto detects it from the first 30 s of speech.",
    .string, "auto")
private let model = Param.defaulted(
    "model", "The model name: base, or small-q5_1 (more accurate and slower).", .string, "base")
private let transcribeName = Param<String?>.optional(
    "name", "The transcript name. The default is the track name.", .string)

private let exportOut = Param.required(
    "out",
    "The absolute path of the subtitle file, outside each session package: .srt or .vtt. It must not exist, unless "
        + "replace.", .string)
private let exportTranscript = Param<Int?>.optional(
    "transcript", "The transcript number. Leave it out when the session has one transcript.", .integer(minimum: 1))
private let exportReplace = Param.defaulted("replace", "Replace the file when it exists.", .boolean, false)

/// The transcript tools (decision 0055): `dirigible transcript import`, `words`, and `cut`;
/// `export` (decision 0061); and `dirigible transcribe` (decision 0065).
let transcriptTools = [
    Tool(
        "transcript_import",
        "Import a Whisper JSON, WebVTT, or SRT transcript of an export of the whole session; the track is the track whose "
            + "clips carry the words. Give the transcript ID and the count of words. A word with no clip of the track "
            + "under it, or with no time, is skipped. A new import replaces the words of an earlier one in the same "
            + "span. With take, the transcript is of the original take, not of an export.",
        [path, text, importTrack, at, take, name], batch: .alone
    ) { a throws(ToolError) in
        // Each argument is checked before the source, so a bad argument gets its own text.
        let (track, frame, given) = (TrackID(try a[importTrack]), Frames(try a[at]), try a[name])
        let takeNumber = try a[take]
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
        if let takeNumber {
            return .takeImport(take: takeNumber) { session, map throws(SessionError) in
                TranscriptWork.importLines(
                    try session.importTranscript(
                        file, name: title, track: track, at: frame, time: .take(takeNumber, map)),
                    cues: file.cues, take: takeNumber)
            }
        }
        return .edit(ripple: false) { session throws(SessionError) in
            TranscriptWork.importLines(
                try session.importTranscript(file, name: title, track: track, at: frame), cues: file.cues)
        }
    },
    Tool(
        "transcript_words",
        "Give the transcript words over the clips, one row each: occurrence, start, end, track, text. The frames "
            + "are timeline frames. Find a passage with match, or read a range with from and to.",
        [from, to, match, wordsTrack, limit, json], saves: false, batch: .alone
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
        [occurrences], batch: .alone
    ) { a throws(ToolError) in
        let words = try TranscriptWork.occurrences(try a[occurrences])
        return .edit(ripple: true) { session throws(SessionError) in
            TranscriptWork.cutLines(try session.cutWords(words))
        }
    },
    Tool(
        "transcribe",
        "Transcribe the clips of a track with whisper.cpp on this Mac, as dirigible transcribe, and add the words as "
            + "a transcript, with the lines of transcript_import. No kept word changes nothing and gives only "
            + "\"Imported 0 words.\" and the skip lines. In the app, a missing model downloads first; on the files, "
            + "the model must be in the model folder." + editCancelNote("no words are added"),
        [transcribeTrack, language, model, transcribeName], batch: .alone
    ) { a throws(ToolError) in
        .transcribe(
            try TranscribeWork(
                track: try a[transcribeTrack], language: try a[language], model: try a[model],
                name: try a[transcribeName]))
    },
    Tool(
        "transcript_export",
        "Write the transcript as subtitles on the timeline now, as dirigible transcript export: one cue for each "
            + "word or cue of the transcript, in timeline order. A .srt out gives SubRip, a .vtt out gives WebVTT. "
            + "The text is the warning lines, or OK.",
        [exportOut, exportTranscript, exportReplace], saves: false, batch: .alone
    ) { a throws(ToolError) in
        // Each argument is checked before `out`, so a bad argument gets its own text.
        let (transcript, replace) = (try a[exportTranscript], try a[exportReplace])
        return .transcriptExport(
            try TranscriptExportWork(out: try outPath(a, exportOut), transcript: transcript, replace: replace))
    },
]
