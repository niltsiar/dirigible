import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

/// The transcript commands (decision 0055). The tools `transcript_import`, `transcript_words`, and
/// `transcript_cut` give the same text: stdout, then stderr.
struct TranscriptCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcript", abstract: "Import a transcript, read its words, cut words, and export subtitles.",
        subcommands: [Import.self, Words.self, Cut.self, Export.self])

    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Import a Whisper JSON, WebVTT, or SRT transcript of an export of the whole session; the track is the track "
                + "whose clips carry the words. Print the transcript ID and the count of words. A word with no clip of the track under it, or with no time, is skipped. A new import "
                + "replaces the words of an earlier one in the same span.",
            discussion:
                "With --take <n>, the transcript is of take n, not of an export: time 0 is the record start of that take, "
                + "and each word lands on the audio of the take where the edits left it. --at is then a take frame. "
                + "Exit 1 when the track has no audio of the take; exit 2 when a take anchor in Capture/ cannot be read."
        )
        @OptionGroup var package: PackageArgument
        @Argument(help: "The transcript file, or - for stdin.") var file: String
        @Option(help: "The track whose clips carry the words.") var track: String
        @Option(
            parsing: .unconditional,
            help: "The timeline frame of second 0 of the transcript, or with --take a take frame.")
        var at = 0
        @Option(help: "The take number, when the transcript is of one take. Time 0 is the record start of the take.")
        var take: Int?
        @Option(help: "The transcript name. The default is the file name, else transcript.") var name: String?

        func validate() throws {
            if let take, take < 1 { throw ValidationError("The take must be 1 or more.") }
        }

        /// A session refusal exits 1; a take anchor that does not read exits 2.
        private func refusedTakeImport(_ error: TakeImportError) -> ExitCode {
            switch error {
            case .session: fail(error.message, code: editRefused)
            case .anchor: fail(error.message, code: packageError)
            }
        }

        func run() throws {
            let transcript: TranscriptFile
            do throws(ToolError) {
                transcript =
                    file == "-"
                    ? try TranscriptWork.file(FileHandle.standardInput.readDataToEndOfFile(), source: "stdin")
                    : try TranscriptWork.file(at: file)
            } catch {
                throw fail(error.message, code: editRefused)
            }
            let title = name ?? (file == "-" ? TranscriptWork.defaultName : URL(filePath: file).lastPathComponent)
            let lines: [String]
            if let take {
                lines = try editPackage(package, ripple: false, refused: refusedTakeImport) {
                    session, _ throws(TakeImportError) in
                    try TranscriptWork.inTake(
                        &session, take: take, read: TakeMap.of(session, anchors: TakeAnchors.result(package.url))
                    ) { session, map throws(SessionError) in
                        TranscriptWork.importLines(
                            try session.importTranscript(
                                transcript, name: title, track: TrackID(track), at: Frames(at), time: .take(take, map)),
                            cues: transcript.cues, take: take)
                    }
                }
            } else {
                lines = try editPackage(package, ripple: false) { session throws(SessionError) in
                    TranscriptWork.importLines(
                        try session.importTranscript(transcript, name: title, track: TrackID(track), at: Frames(at)),
                        cues: transcript.cues)
                }
            }
            print(lines.prefix(2).joined(separator: "\n"))
            warn(Array(lines.dropFirst(2)))
        }
    }

    struct Words: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Print the transcript words over the clips, one row each: occurrence, start, end, track, text, with a "
                + "tab between them. The frames are timeline frames.")
        @OptionGroup var package: PackageArgument
        @Option(parsing: .unconditional, help: "Only the words that touch this frame on. Give it with --to.")
        var from: Int?
        @Option(parsing: .unconditional, help: "Only the words before this frame. Give it with --from.") var to: Int?
        @Option(help: "Only the runs of words that say this phrase. Case and punctuation do not count.")
        var match: String?
        @Option(help: "Only the words over the clips of this track.") var track: String?
        @Option(help: "The most rows to print, 1 or more.") var limit = 200
        @Flag(help: "Print JSON in place of the rows.") var json = false

        func validate() throws { _ = try query() }

        func run() throws {
            let (query, session) = (try query(), try readPackage(package))
            do throws(ToolError) {
                print(try TranscriptWork.wordsText(session, query))
            } catch {
                throw fail(error.message, code: editRefused)
            }
        }

        func query() throws(ValidationError) -> TranscriptQuery {
            do throws(ToolError) {
                return try TranscriptQuery(from: from, to: to, match: match, track: track, limit: limit, json: json)
            } catch {
                throw ValidationError(error.message)
            }
        }
    }

    struct Cut: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Cut the words with these occurrences from all tracks, and close each gap, in one edit. Words next to "
                + "each other cut as one range. Print the frames of each cut range.")
        @OptionGroup var package: PackageArgument
        @Argument(help: "The word occurrences: the first column of transcript words.") var occurrences: [String]

        func validate() throws { _ = try words() }

        func run() throws {
            let words = try words()
            let ranges = try editPackage(package, ripple: true) { session throws(SessionError) in
                try session.cutWords(words)
            }
            print(TranscriptWork.cutLines(ranges).joined(separator: "\n"))
        }

        func words() throws(ValidationError) -> [WordOccurrence] {
            guard !occurrences.isEmpty else { throw ValidationError("Give one or more word occurrences.") }
            do throws(ToolError) { return try TranscriptWork.occurrences(occurrences) } catch {
                throw ValidationError(error.message)
            }
        }
    }

    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write the transcript as an SRT or WebVTT file on the timeline as it is now.",
            discussion:
                "One cue for each word or cue of the transcript, in timeline order, with the times of transcript "
                + "words in whole milliseconds. The extension of --out gives the form: .srt or .vtt. A cue that an "
                + "edit cut is clamped to the audio that stays. Exit 64 when --out is not .srt or .vtt or is in a "
                + ".dirigible package. Exit 1 when the session has no transcript, has more than one and no "
                + "--transcript, or the transcript has no word on the timeline. Exit 2 when the package cannot be "
                + "read, --out exists (unless --replace), or the write fails. The write is atomic: a failed write "
                + "leaves the old file.")
        @OptionGroup var package: PackageArgument
        @Option(help: "The output file: .srt or .vtt.") var out: String
        @Option(help: "The transcript number. Give it when the session has more than one transcript.")
        var transcript: Int?
        @Flag(help: "Replace the output file when it exists.") var replace = false

        func work() throws(ValidationError) -> TranscriptExportWork {
            do throws(ToolError) {
                return try TranscriptExportWork(out: out, transcript: transcript, replace: replace, spelling: .cli)
            } catch {
                throw ValidationError(error.message)
            }
        }

        func validate() throws { _ = try work() }

        func run() throws {
            let work = try work()
            let session = try readPackage(package)
            let text: String
            let warnings: [String]
            do throws(ToolError) { (text, warnings) = try work.render(session) } catch {
                throw fail(error.message, code: editRefused)
            }
            warn(warnings)
            do throws(ToolError) {
                try work.checkTarget()
                try work.write(text)
            } catch {
                throw fail(error.message, code: packageError)
            }
        }
    }
}
