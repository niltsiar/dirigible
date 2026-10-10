import Foundation
import Testing

@testable import DirigibleCore

/// The episode in the session and in `session.xml` version 6 (decision 0045, criteria C1, C2).
struct EpisodeSessionTests {
    let package = FileManager.default.temporaryDirectory
        .appending(path: "EpisodeSessionTests-\(UUID().uuidString)/Episode.dirigible")

    static func fullEpisode() throws -> Episode {
        var episode = Episode()
        episode.title = try EpisodeLine("Episodio 12: Café & <ñandú>")
        episode.show = try EpisodeLine("The \"Show\"")
        episode.author = try EpisodeLine("Ana Pérez")
        episode.number = try EpisodeNumber(12)
        episode.season = try EpisodeNumber(3)
        episode.date = try CalendarDate("2026-10-09")
        episode.language = try LanguageCode("spa")
        episode.copyright = try EpisodeLine("© 2026 Ana")
        episode.explicit = true
        episode.summary = try EpisodeNotes("Short\ndescription")
        episode.notes = try EpisodeNotes("  a\n\n\tb  ")
        episode.episodeURL = try WebURL("https://example.com/ep12")
        episode.feedURL = try WebURL("https://example.com/feed.xml")
        episode.guid = try EpisodeLine("urn:uuid:1234")
        return episode
    }

    /// The XML text of a session with `episode`, with its version attribute set to `version`.
    func xml(_ episode: Episode, version: Int) throws -> Data {
        var session = Session(sampleRate: 48_000)
        session.setEpisode(episode)
        try session.write(to: package)
        let text = try String(contentsOf: package.appending(path: "session.xml"), encoding: .utf8)
        return Data(text.replacingOccurrences(of: "version=\"6\"", with: "version=\"\(version)\"").utf8)
    }

    @Test func anEpisodeRoundTripsThroughSessionXML() throws {
        let episode = try Self.fullEpisode()
        var session = Session(sampleRate: 48_000)
        session.setEpisode(episode)

        try session.write(to: package)
        let read = try Session(contentsOf: package)

        #expect(read.episode == episode, "read back: \(read.episode)")
        #expect(read == session)
        let text = try String(contentsOf: package.appending(path: "session.xml"), encoding: .utf8)
        #expect(text.contains("<notes>  a\n\n\tb  </notes>"), "the notes are element text")
    }

    @Test func anEmptyEpisodeKeepsTheVersionAndOneFieldGivesSix() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setMuted(true, tracks: ["t1"])
        session.setEpisode(Episode())
        #expect(session.fileVersion == 5, "an empty episode keeps version 5 of a muted track")

        var episode = Episode()
        episode.explicit = true
        session.setEpisode(episode)
        #expect(session.fileVersion == 6, "the explicit flag alone gives version 6")
        try session.write(to: package)
        #expect(
            try String(contentsOf: package.appending(path: "session.xml"), encoding: .utf8).contains("version=\"6\""))
        #expect(Session(sampleRate: 48_000).fileVersion == 1)
    }

    @Test func theReaderRefusesAnEpisodeBeforeVersionSix() throws {
        let episode = try Self.fullEpisode()
        #expect(throws: SessionFileError.invalidValue(element: "episode", attribute: "version")) {
            try Session(xml: try xml(episode, version: 5))
        }
        #expect(throws: SessionFileError.unsupportedVersion(6)) {
            try Session(xml: try xml(episode, version: 6), newest: 5)
        }
        #expect(try Session(xml: try xml(episode, version: 6)).episode == episode)
    }

    @Test func theReaderRefusesABadField() throws {
        let data = try xml(try Self.fullEpisode(), version: 6)
        let text = String(decoding: data, as: UTF8.self)
        let cases = [
            ("number=\"12\"", "number=\"0\"", "number"), ("date=\"2026-10-09\"", "date=\"2026-02-30\"", "date"),
            ("language=\"spa\"", "language=\"es\"", "language"), ("explicit=\"true\"", "explicit=\"yes\"", "explicit"),
            ("feedURL=\"https://example.com/feed.xml\"", "feedURL=\"ftp://a.b\"", "feedURL"),
        ]
        for (old, new, attribute) in cases {
            #expect(text.contains(old), "the fixture has \(old)")
            let bad = Data(text.replacingOccurrences(of: old, with: new).utf8)
            #expect(throws: SessionFileError.invalidValue(element: "episode", attribute: attribute)) {
                try Session(xml: bad)
            }
        }
    }

    @Test func setEpisodeIsOneUndoEntry() throws {
        var history = History(Session(sampleRate: 48_000))
        let episode = try Self.fullEpisode()
        history.edit { session in session.setEpisode(episode) }
        #expect(history.session.episode == episode)
        try history.undo()
        #expect(history.session.episode.isEmpty && !history.canUndo)
    }

    /// Seeded round trip: random field sets read back equal.
    @Test func randomEpisodesRoundTrip() throws {
        var random = SplitMix(seed: 45)
        let full = try Self.fullEpisode()
        let keys: [WritableKeyPath<Episode, EpisodeLine?>] = [\.title, \.show, \.author, \.copyright, \.guid]
        for _ in 0..<20 {
            var episode = Episode()
            for key in keys where Bool.random(using: &random) { episode[keyPath: key] = full[keyPath: key] }
            if Bool.random(using: &random) {
                episode.number = try EpisodeNumber(Int.random(in: 1...999, using: &random))
            }
            if Bool.random(using: &random) { episode.notes = full.notes }
            if Bool.random(using: &random) { episode.episodeURL = full.episodeURL }
            episode.explicit = Bool.random(using: &random)
            var session = Session(sampleRate: 48_000)
            session.setEpisode(episode)
            try session.write(to: package)
            #expect(try Session(contentsOf: package).episode == episode)
        }
    }
}
