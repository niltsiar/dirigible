import Foundation
import Testing

@testable import DirigibleCore

/// The rule of a new session from a template (decision draft "session templates", T1 and T2). The
/// show is a 48 kHz session with the tracks Host (mono, -3 dB, muted, dialogue) and Music (stereo,
/// soloed, music). Host plays "used" (capture cap1) in clip A and "rendered" (origin "source") in
/// clip B. "unused" (capture cap2) and "spare" have no clip; "source" has no clip but is the origin
/// source of "rendered". A transcript covers clip A, and the marker "m1" has an image.
struct SessionTemplateTests {
    let artwork = try! ArtworkName("0B1E1F4C-8F0E-4C3B-9F1A-2B7D4E6A9C01.jpg")
    let chapterImage = try! ArtworkName("6A0C2D1B-3E4F-4A5B-8C7D-9E0F1A2B3C4D.png")

    func capture(_ id: CaptureID) -> Capture {
        Capture(
            id: id, deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: 1_000, sampleTime: 512,
            nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 64)
    }

    func show() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addCapture(capture("cap1"))
        try session.addCapture(capture("cap2"))
        try session.addFile(AudioFile(id: "used", path: "used.wav", layout: .mono, length: 480_000, capture: "cap1"))
        try session.addFile(AudioFile(id: "unused", path: "unused.wav", layout: .mono, length: 48_000, capture: "cap2"))
        try session.addFile(AudioFile(id: "spare", path: "sub/spare.wav", layout: .stereo, length: 48_000))
        try session.addFile(AudioFile(id: "source", path: "source.wav", layout: .mono, length: 960_000))
        let origin = RenderOrigin(
            source: "source", offset: 0, treatment: Treatment(.noise(.standard)), addedGain: try #require(Gain(dB: 0)))
        try session.addFile(
            AudioFile(id: "rendered", path: "rendered.wav", layout: .mono, length: 96_000, origin: origin))
        try session.addTrack("host", name: "Host", layout: .mono)
        try session.addTrack("music", name: "Music", layout: .stereo)
        try session.setGain(try #require(Gain(dB: -3)), track: "host")
        try session.setMuted(true, tracks: ["host"])
        try session.setSoloed(true, tracks: ["music"])
        try session.setRole(.dialogue, tracks: ["host"])
        try session.setRole(.music, tracks: ["music"])
        try session.place(Clip(id: "A", file: "used", start: 0, offset: 0, length: 240_000), on: "host")
        try session.place(Clip(id: "B", file: "rendered", start: 300_000, offset: 0, length: 96_000), on: "host")
        try session.setMarker(Marker(id: "m1", name: "Intro", position: 0, kind: .chapter, image: chapterImage))
        try session.setMarker(Marker(id: "m2", name: "Ad", position: 100_000, kind: .marker))
        var episode = Episode()
        try episode.set(.title, text: "Episode 12")
        try episode.set(.show, text: "The Show")
        try episode.set(.author, text: "The Host")
        try episode.set(.number, text: "12")
        try episode.set(.season, text: "3")
        try episode.set(.date, text: "2026-11-21")
        try episode.set(.language, text: "spa")
        try episode.set(.copyright, text: "CC BY")
        try episode.set(.summary, text: "A short summary.")
        try episode.set(.notes, text: "Long notes.")
        try episode.set(.episodeURL, text: "https://example.com/12")
        try episode.set(.feedURL, text: "https://example.com/feed")
        try episode.set(.guid, text: "guid-12")
        episode.explicit = true
        episode.artwork = artwork
        session.setEpisode(episode)
        let json = #"{"words":[{"word":"hello","start":1,"end":1.5},{"word":"there","start":2,"end":2.5}]}"#
        try session.importTranscript(try TranscriptFile(data: Data(json.utf8)), name: "t.json", track: "host", at: 0)
        return session
    }

    /// T1: each episode field of one episode is clear, each show field keeps its value, and the
    /// tracks, the clips with their IDs, and the markers do not change.
    @Test func aNewEpisodeKeepsTheShowAndClearsTheEpisode() throws {
        let source = try show()

        let new = try source.newEpisode().session

        let episode = new.episode
        #expect(episode.title == nil, "title")
        #expect(episode.number == nil, "number")
        #expect(episode.date == nil, "date")
        #expect(episode.summary == nil, "summary")
        #expect(episode.notes == nil, "notes")
        #expect(episode.episodeURL == nil, "episode URL")
        #expect(episode.guid == nil, "GUID")
        #expect(episode.show?.text == "The Show", "show")
        #expect(episode.author?.text == "The Host", "author")
        #expect(episode.season?.description == "3", "season")
        #expect(episode.language?.code == "spa", "language")
        #expect(episode.copyright?.text == "CC BY", "copyright")
        #expect(episode.explicit, "explicit")
        #expect(episode.feedURL?.text == "https://example.com/feed", "feed URL")
        #expect(episode.artwork == artwork, "artwork")
        #expect(new.sampleRate == 48_000)
        #expect(new.tracks == source.tracks, "the tracks with each property and each clip with its ID")
        #expect(new.tracks.map(\.name) == ["Host", "Music"] && new.track("host")?.clips.map(\.id) == ["A", "B"])
        #expect(new.markers == source.markers && new.markers.count == 2)
    }

    /// T2: the transcripts, each file outside `filesInUse`, and each capture that no kept file
    /// names go; the copy list names each kept file in `Clips/`, the artwork, and the marker image.
    @Test func aNewEpisodeDropsTheTranscriptsAndTheUnusedFiles() throws {
        let source = try show()
        #expect(!source.transcripts.isEmpty && source.files.count == 5 && source.captures.count == 2)

        let new = try source.newEpisode()

        #expect(new.session.transcripts.isEmpty)
        #expect(Set(new.session.files.keys) == ["used", "rendered", "source"])
        #expect(Set(new.session.captures.keys) == ["cap1"], "cap2 named only the unused file")
        #expect(
            new.filePaths.sorted()
                == [
                    "Artwork/\(artwork.name)", "Artwork/\(chapterImage.name)", "Clips/rendered.wav", "Clips/source.wav",
                    "Clips/used.wav",
                ].sorted())
    }

    /// T2: the kept file IDs equal `filesInUse` of the source, for a session with clips, an origin
    /// chain, and unused files, and for one with no clip.
    @Test func aNewEpisodeKeepsEachFileInUse() throws {
        var bare = Session(sampleRate: 44_100)
        try bare.addFile(AudioFile(id: "lone", path: "lone.wav", layout: .mono, length: 100))
        for source in [try show(), bare] {
            let new = try source.newEpisode().session

            #expect(Set(new.files.keys) == source.filesInUse)
        }
        #expect(try show().filesInUse.contains("source"), "the origin source has no clip and is in use")
    }

    /// T2: a session with a take that is not finalized gives no new episode.
    @Test func aNewEpisodeOfAPendingTakeThrows() throws {
        var source = try show()
        try source.setRecording(
            Recording(take: 2, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["host"]))

        #expect(throws: SessionError.pendingTake) { try source.newEpisode() }
    }

    /// E5: a new episode keeps the export presets of the show, in their order.
    @Test func aNewEpisodeKeepsTheExportPresets() throws {
        var source = try show()
        try source.setExportPreset(ExportPresetTests.preset("Show", ExportPresetTests.wav))
        try source.setExportPreset(ExportPresetTests.preset("Feed"))

        let new = try source.newEpisode().session

        #expect(new.exportPresets == source.exportPresets && ExportPresetTests.names(new) == ["Show", "Feed"])
    }
}
