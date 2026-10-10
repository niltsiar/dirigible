import ArgumentParser
import DirigibleAudio
import DirigibleCore
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
        @Option(help: "The episode number, 1 or more.") var episode: String?
        @Option(help: "The season number, 1 or more.") var season: String?
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
                fields.notes = String(decoding: data, as: UTF8.self)
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
            let session = try readPackage(package)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            print(String(decoding: try encoder.encode(EpisodeView(session.episode)), as: UTF8.self))
        }
    }
}

/// The exit of a refused image (1, as `dirigible import` of a file that is not audio) or a failed
/// copy (2).
private func refusedArtwork(_ error: ArtworkError) -> ExitCode {
    if case .writeFailed = error { return fail(error.message, code: packageError) }
    return fail(error.message, code: editRefused)
}

/// The given episode fields as text, from the CLI or an MCP tool. Nil leaves a field unchanged;
/// an empty text clears it. `artwork` is the path of an image file.
struct EpisodeFields: Sendable {
    var title, show, author, episode, season, date, language, copyright: String?
    var explicit: Bool?
    var summary, notes, episodeURL, feedURL, guid, artwork: String?

    /// Parses each given field into its type, so a bad value refuses the whole change before the
    /// package lock.
    func work() throws(EpisodeFieldError) -> EpisodeWork {
        func parse<T>(_ text: String?, _ make: (String) throws(EpisodeFieldError) -> T?) throws(EpisodeFieldError)
            -> T??
        {
            guard let text else { return .none }
            return .some(text.isEmpty ? nil : try make(text))
        }
        let number = { (text: String) throws(EpisodeFieldError) in try EpisodeNumber(text: text) }
        let parsed = (
            title: try parse(title, EpisodeLine.init), show: try parse(show, EpisodeLine.init),
            author: try parse(author, EpisodeLine.init), episode: try parse(episode, number),
            season: try parse(season, number), date: try parse(date, CalendarDate.init),
            language: try parse(language, LanguageCode.init), copyright: try parse(copyright, EpisodeLine.init),
            summary: try parse(summary, EpisodeNotes.init), notes: try parse(notes, EpisodeNotes.init),
            episodeURL: try parse(episodeURL, WebURL.init), feedURL: try parse(feedURL, WebURL.init),
            guid: try parse(guid, EpisodeLine.init)
        )
        let explicit = explicit
        return EpisodeWork(artwork: artwork) { episode in
            if let value = parsed.title { episode.title = value }
            if let value = parsed.show { episode.show = value }
            if let value = parsed.author { episode.author = value }
            if let value = parsed.episode { episode.number = value }
            if let value = parsed.season { episode.season = value }
            if let value = parsed.date { episode.date = value }
            if let value = parsed.language { episode.language = value }
            if let value = parsed.copyright { episode.copyright = value }
            if let explicit { episode.explicit = explicit }
            if let value = parsed.summary { episode.summary = value }
            if let value = parsed.notes { episode.notes = value }
            if let value = parsed.episodeURL { episode.episodeURL = value }
            if let value = parsed.feedURL { episode.feedURL = value }
            if let value = parsed.guid { episode.guid = value }
        }
    }
}

/// An episode edit of the CLI or an MCP tool: the parsed fields, and an image file that the edit
/// copies into the package under the lock.
struct EpisodeWork: Sendable {
    /// Nil: no change. Empty: no artwork.
    let artwork: String?
    let change: @Sendable (inout Episode) -> Void

    func run(_ session: inout Session, package: URL) throws(ArtworkError) {
        var episode = session.episode
        change(&episode)
        if let artwork {
            episode.artwork = artwork.isEmpty ? nil : try importArtwork(URL(filePath: artwork), into: package)
        }
        session.setEpisode(episode)
    }
}

/// The JSON of an episode: the `session.xml` names, and only the set fields.
struct EpisodeView: Encodable {
    let title, show, author: String?
    let number, season: Int?
    let date, language, copyright: String?
    let explicit: Bool?
    let summary, notes, episodeURL, feedURL, guid: String?
    /// The path in the package.
    let artwork: String?

    init(_ episode: Episode) {
        (title, show, author) = (episode.title?.text, episode.show?.text, episode.author?.text)
        (number, season) = (episode.number?.value, episode.season?.value)
        (date, language, copyright) = (episode.date?.description, episode.language?.code, episode.copyright?.text)
        explicit = episode.explicit ? true : nil
        (summary, notes) = (episode.summary?.text, episode.notes?.text)
        (episodeURL, feedURL, guid) = (episode.episodeURL?.text, episode.feedURL?.text, episode.guid?.text)
        artwork = episode.artwork?.path
    }
}
