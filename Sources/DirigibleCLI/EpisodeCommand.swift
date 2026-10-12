import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

struct EpisodeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "episode", abstract: "Set and show the episode metadata of the MP3 and M4A exports.",
        subcommands: [SetEpisode.self, Show.self])

    struct SetEpisode: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set episode fields. An empty value clears its field. The other fields do not change.")
        @OptionGroup var package: PackageArgument
        @Option var title: String?
        @Option(help: "The show name (the album).") var show: String?
        @Option(help: "The host or author (the artist).") var author: String?
        @Option(help: "The episode number, from 1 to \(EpisodeNumber.maximum).") var episode: String?
        @Option(help: "The season number, from 1 to \(EpisodeNumber.maximum).") var season: String?
        @Option(help: "The date, YYYY-MM-DD.") var date: String?
        @Option(help: "An ISO 639-2 code, for example eng or spa.") var language: String?
        @Option var copyright: String?
        @Option(help: "true or false.") var explicit: String?
        @Option(help: "The short description.") var summary: String?
        @Option(help: "The episode notes.") var notes: String?
        @Option(help: "A file with the episode notes, or - for stdin.") var notesFile: String?
        @Option(help: "An http or https URL.") var episodeURL: String?
        @Option(help: "An http or https URL.") var feedURL: String?
        @Option(help: "The episode GUID.") var guid: String?
        @Option(
            help: ArgumentHelp(
                "A square JPEG or PNG file, at most \(maximumArtworkSide) x \(maximumArtworkSide) pixels.",
                discussion: "The command copies it into Artwork/. An empty value removes the artwork from the "
                    + "episode; the file stays."))
        var artwork: String?

        func validate() throws {
            if notes != nil && notesFile != nil { throw ValidationError("Give --notes or --notes-file, not both.") }
        }

        func run() throws {
            var fields = EpisodeFields(
                title: title, show: show, author: author, episode: episode, season: season, date: date,
                language: language, copyright: copyright, explicit: nil, summary: summary, notes: notes,
                episodeURL: episodeURL, feedURL: feedURL, guid: guid, artwork: artwork)
            switch explicit {
            case nil: break
            case "true": fields.explicit = true
            case "false": fields.explicit = false
            default: throw ValidationError("--explicit is true or false.")
            }
            if let notesFile {
                let data =
                    notesFile == "-"
                    ? FileHandle.standardInput.readDataToEndOfFile()
                    : try Data(contentsOf: URL(filePath: notesFile))
                guard let text = String(data: data, encoding: .utf8) else {
                    throw ValidationError("--notes-file is not UTF-8 text.")
                }
                fields.notes = text
            }
            let work: EpisodeWork
            do throws(EpisodeFieldError) { work = try fields.work() } catch {
                throw ValidationError(error.message)
            }
            try editPackage(package, refused: refusedArtwork) { session, _ throws(ArtworkError) in
                try work.run(&session, package: package.url)
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the episode fields as JSON.")
        @OptionGroup var package: PackageArgument

        func run() throws {
            print(try EpisodeView(try readPackage(package).episode).json(pretty: true))
        }
    }
}

/// The exit of a refused image (1, as `dirigible import` of a file that is not audio) or a failed
/// copy (2).
private func refusedArtwork(_ error: ArtworkError) -> ExitCode {
    if case .writeFailed = error { return fail(error.message, code: packageError) }
    return fail(error.message, code: editRefused)
}
