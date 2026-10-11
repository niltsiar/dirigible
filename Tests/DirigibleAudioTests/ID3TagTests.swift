import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The ID3v2.3 tag of an MP3 export (decision 0045, criterion C5): AVFoundation reads each frame
/// back, and the tag does not change the decoded length.
struct ID3TagTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ID3TagTests-\(UUID().uuidString)")

    /// An episode with each field: a non-ASCII title, and notes with LF, a tab, and over 127 bytes.
    static func fullEpisode() throws -> Episode {
        var episode = Episode()
        episode.title = try EpisodeLine("Episodio 12: Café ñandú")
        episode.show = try EpisodeLine("The Show")
        episode.author = try EpisodeLine("Ana Pérez")
        episode.number = try EpisodeNumber(12)
        episode.season = try EpisodeNumber(3)
        episode.date = try CalendarDate("2026-10-09")
        episode.language = try LanguageCode("spa")
        episode.copyright = try EpisodeLine("© 2026 Ana")
        episode.explicit = true
        episode.summary = EpisodeNotes("Short description")
        episode.notes = EpisodeNotes("Line 1\n\tLine 2\n" + String(repeating: "más notas ", count: 20))
        episode.episodeURL = try WebURL("https://example.com/ep12")
        episode.feedURL = try WebURL("https://example.com/feed.xml")
        episode.guid = try EpisodeLine("urn:uuid:1234")
        return episode
    }

    /// Writes 1 s of a stereo sine at 48 kHz through `writeMP3` with `tag`.
    func writeSine(_ name: String, tag: [UInt8]) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for channel in 0..<2 {
            for index in 0..<48_000 { buffer.floatChannelData![channel][index] = Float(0.1 * sin(Double(index) / 8)) }
        }
        try writeMP3(url, bitRate: .k128, rate: 48_000, client: format, tag: tag) { sink throws(ExportError) in
            try sink(buffer)
        }
        return url
    }

    /// The ID3 frames that AVFoundation reads, by identifier, as a string or the data size.
    static func frames(_ url: URL) async throws -> [String: String] {
        var result: [String: String] = [:]
        for item in try await AVURLAsset(url: url).loadMetadata(for: .id3Metadata) {
            let value = try await item.load(.value)
            let shown =
                if let data = value as? Data { "data:" + data.map { String(format: "%02x", $0) }.joined() } else {
                    value.map { "\($0)" } ?? "nil"
                }
            result[item.identifier?.rawValue ?? "?"] = shown
        }
        return result
    }

    @Test func aTaggedMP3ReadsBackEveryFrame() async throws {
        let episode = try Self.fullEpisode()
        let tagged = try writeSine("tagged.mp3", tag: id3Tag(episode))
        let plain = try writeSine("plain.mp3", tag: [])

        let bytes = try #require(FileManager.default.contents(atPath: tagged.path))
        #expect(bytes.prefix(5) == Data("ID3".utf8) + Data([3, 0]), "the file does not start with an ID3v2.3 header")
        let frames = try await Self.frames(tagged)
        let expected: [String: String] = [
            "id3/TIT2": "Episodio 12: Café ñandú", "id3/TALB": "The Show", "id3/TPE1": "Ana Pérez",
            "id3/TPE2": "Ana Pérez", "id3/TRCK": "12", "id3/TPOS": "3", "id3/TYER": "2026", "id3/TDAT": "0910",
            "id3/TCON": "Podcast", "id3/TLAN": "spa", "id3/TCOP": "© 2026 Ana", "id3/TXXX": "1",
            "id3/COMM": "Short description", "id3/TDES": episode.notes!.text, "id3/TGID": "urn:uuid:1234",
            "id3/WOAF": "https://example.com/ep12", "id3/WXXX": "https://example.com/ep12",
            "id3/PCST": "data:00000001", "id3/WFED": "https://example.com/feed.xml",
        ]
        for (identifier, value) in expected {
            #expect(frames[identifier] == value, "\(identifier) reads \(frames[identifier] ?? "nothing")")
        }
        let taggedLength = try AVAudioFile(forReading: tagged).length
        let plainLength = try AVAudioFile(forReading: plain).length
        #expect(
            taggedLength == 48_000 && plainLength == 48_000, "lengths \(taggedLength) and \(plainLength), not 48000")
    }

    @Test func anEmptyEpisodeWritesNoTag() throws {
        var episode = Episode()
        #expect(try id3Tag(episode).isEmpty)
        episode.summary = EpisodeNotes("\t")
        episode.notes = EpisodeNotes(" \t\n")
        #expect(try id3Tag(episode).isEmpty, "a whitespace-only text is no value")

        let url = try writeSine("plain.mp3", tag: id3Tag(episode))
        let bytes = try #require(FileManager.default.contents(atPath: url.path))
        #expect(bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0, "the file does not start with an MPEG frame")
    }
}
