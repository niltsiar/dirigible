import ArgumentParser
import DirigibleCore
import DirigibleMCP
import Foundation

/// The transcript commands (decision 0055). The tools `transcript_import`, `transcript_words`, and
/// `transcript_cut` give the same text: stdout, then stderr.
struct TranscriptCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcript", abstract: "Import a transcript, read its words, and cut words.",
        subcommands: [Import.self, Words.self, Cut.self])

    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Import a Whisper JSON or WebVTT transcript of the audio on one track, and print its ID and the count "
                + "of words. A word with no clip of the track under it, or with no time, is skipped. A new import "
                + "replaces the words of an earlier one in the same span.")
        @OptionGroup var package: PackageArgument
        @Argument(help: "The transcript file, or - for stdin.") var file: String
        @Option(help: "The track whose clips the words are spoken in.") var track: String
        @Option(parsing: .unconditional, help: "The timeline frame of second 0 of the transcript.") var at = 0
        @Option(help: "The transcript name. The default is the file name, else transcript.") var name: String?

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
            let lines = try editPackage(package) { session throws(SessionError) in
                TranscriptWork.importLines(
                    try session.importTranscript(transcript, name: title, track: TrackID(track), at: Frames(at)))
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
}
