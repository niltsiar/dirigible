import ArgumentParser
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

        func validate() throws {
            if notes != nil && notesFile != nil { throw ValidationError("Give --notes or --notes-file, not both.") }
        }

        func run() throws {
            var fields = EpisodeFields(
                title: title, show: show, author: author, episode: episode, season: season, date: date,
                language: language, copyright: copyright, explicit: nil, summary: summary, notes: notes,
                episodeURL: episodeURL, feedURL: feedURL, guid: guid)
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
            let change: (inout Episode) -> Void
            do throws(EpisodeFieldError) { change = try fields.change() } catch {
                throw ValidationError(error.message)
            }
            try editPackage(package) { session throws(SessionError) in
                var episode = session.episode
                change(&episode)
                session.setEpisode(episode)
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

/// The given episode fields as text, from the CLI or an MCP tool. Nil leaves a field unchanged;
/// an empty text clears it.
struct EpisodeFields: Sendable {
    var title, show, author, episode, season, date, language, copyright: String?
    var explicit: Bool?
    var summary, notes, episodeURL, feedURL, guid: String?

    /// Parses each given field into its type, so a bad value refuses the whole change before the
    /// package lock.
    func change() throws(EpisodeFieldError) -> @Sendable (inout Episode) -> Void {
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
        return { episode in
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

/// The JSON of an episode: the `session.xml` names, and only the set fields.
struct EpisodeView: Encodable {
    let title, show, author: String?
    let number, season: Int?
    let date, language, copyright: String?
    let explicit: Bool?
    let summary, notes, episodeURL, feedURL, guid: String?

    init(_ episode: Episode) {
        (title, show, author) = (episode.title?.text, episode.show?.text, episode.author?.text)
        (number, season) = (episode.number?.value, episode.season?.value)
        (date, language, copyright) = (episode.date?.description, episode.language?.code, episode.copyright?.text)
        explicit = episode.explicit ? true : nil
        (summary, notes) = (episode.summary?.text, episode.notes?.text)
        (episodeURL, feedURL, guid) = (episode.episodeURL?.text, episode.feedURL?.text, episode.guid?.text)
    }
}
