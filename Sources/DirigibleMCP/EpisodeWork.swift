import DirigibleAudio
import DirigibleCore
import Foundation

/// The given episode fields as text, from the CLI or an MCP tool. Nil leaves a field unchanged;
/// an empty text clears it. `artwork` is the path of an image file.
package struct EpisodeFields: Sendable {
    package var title, show, author, episode, season, date, language, copyright: String?
    package var explicit: Bool?
    package var summary, notes, episodeURL, feedURL, guid, artwork: String?

    package init(
        title: String?, show: String?, author: String?, episode: String?, season: String?, date: String?,
        language: String?, copyright: String?, explicit: Bool?, summary: String?, notes: String?,
        episodeURL: String?, feedURL: String?, guid: String?, artwork: String?
    ) {
        (self.title, self.show, self.author, self.episode, self.season) = (title, show, author, episode, season)
        (self.date, self.language, self.copyright, self.explicit) = (date, language, copyright, explicit)
        (self.summary, self.notes, self.episodeURL, self.feedURL) = (summary, notes, episodeURL, feedURL)
        (self.guid, self.artwork) = (guid, artwork)
    }

    /// Checks each given field with the rule of the Episode pane (`Episode.set`), so a bad value
    /// refuses the whole change before the package lock.
    package func work() throws(EpisodeFieldError) -> EpisodeWork {
        let given: [(EpisodeField, String?)] = [
            (.title, title), (.show, show), (.author, author), (.number, episode), (.season, season), (.date, date),
            (.language, language), (.copyright, copyright), (.summary, summary), (.notes, notes),
            (.episodeURL, episodeURL), (.feedURL, feedURL), (.guid, guid),
        ]
        let texts = given.compactMap { field, text in text.map { (field, $0) } }
        var checked = Episode()
        for (field, text) in texts { try checked.set(field, text: text) }
        let explicit = explicit
        return EpisodeWork(artwork: artwork) { episode in
            // The check above accepted each text, and `set` does not read the other fields.
            for (field, text) in texts { try? episode.set(field, text: text) }
            if let explicit { episode.explicit = explicit }
        }
    }
}

/// An episode edit of the CLI or an MCP tool: the parsed fields, and an image file that the edit
/// copies into the package under the lock.
package struct EpisodeWork: Sendable {
    /// Nil: no change. Empty: no artwork.
    let artwork: String?
    let change: @Sendable (inout Episode) -> Void

    package func run(_ session: inout Session, package: URL) throws(ArtworkError) {
        var episode = episode(from: session.episode)
        if let artwork, !artwork.isEmpty { episode.artwork = try importArtwork(URL(filePath: artwork), into: package) }
        session.setEpisode(episode)
    }

    /// The episode after this edit, with no image file read: an empty `artwork` removes the
    /// artwork, and a path keeps the old one. The live path of an agent runs it in `Studio.edit`
    /// (decision 0046).
    package func episode(from old: Episode) -> Episode {
        var episode = old
        change(&episode)
        if artwork == "" { episode.artwork = nil }
        return episode
    }
}

/// The JSON of an episode: the argument names of `episode_set`, and only the set fields.
package struct EpisodeView: Encodable {
    enum CodingKeys: String, CodingKey {
        case title, show, author, season, date, language, copyright, explicit, summary, notes, guid, artwork
        case number = "episode"
        case episodeURL = "episode_url"
        case feedURL = "feed_url"
    }

    let title, show, author: String?
    let number, season: Int?
    let date, language, copyright: String?
    let explicit: Bool?
    let summary, notes, episodeURL, feedURL, guid: String?
    /// The path in the package.
    let artwork: String?

    package init(_ episode: Episode) {
        (title, show, author) = (episode.title?.text, episode.show?.text, episode.author?.text)
        (number, season) = (episode.number?.value, episode.season?.value)
        (date, language, copyright) = (episode.date?.description, episode.language?.code, episode.copyright?.text)
        explicit = episode.explicit ? true : nil
        (summary, notes) = (episode.summary?.text, episode.notes?.text)
        (episodeURL, feedURL, guid) = (episode.episodeURL?.text, episode.feedURL?.text, episode.guid?.text)
        artwork = episode.artwork?.path
    }

    package func json(pretty: Bool) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
