import DirigibleCore
import Foundation
import Testing

@testable import DirigibleTimeline

/// The text of the transcript pane (run transcript-1, landing 2, criteria P3 and P4). Each test
/// builds a session through the public import, so the words have the clips and frames of a real
/// session.
struct TranscriptTextTests {
    /// A unit as (start frame, end frame, text).
    typealias Spoken = (Int, Int, String)

    struct Voice {
        let id: String
        let name: String
        let file: TranscriptFile

        init(_ id: String, _ name: String, _ units: [Spoken], rate: Int = 48_000) throws {
            struct Word: Encodable { let word: String, start: Double, end: Double }
            struct Words: Encodable { let words: [Word] }
            let words = units.map {
                Word(word: " " + $0.2, start: Double($0.0) / Double(rate), end: Double($0.1) / Double(rate))
            }
            self.id = id
            self.name = name
            file = try TranscriptFile(data: JSONEncoder().encode(Words(words: words)))
        }

        init(_ id: String, _ name: String, vtt: String) throws {
            self.id = id
            self.name = name
            file = try TranscriptFile(data: Data(vtt.utf8))
        }
    }

    /// One mono track for each voice, with one clip over the whole file, and one transcript for
    /// each track.
    static func session(rate: Int = 48_000, _ voices: [Voice]) throws -> Session {
        var session = Session(sampleRate: rate)
        for voice in voices {
            let file = FileID(voice.id + "-file")
            try session.addTrack(TrackID(voice.id), name: voice.name, layout: .mono)
            try session.addFile(AudioFile(id: file, path: voice.id + ".wav", layout: .mono, length: 1_000_000_000))
            try session.place(
                Clip(id: ClipID(voice.id + "-clip"), file: file, start: 0, offset: 0, length: 1_000_000_000),
                on: TrackID(voice.id))
            try session.importTranscript(voice.file, name: voice.name, track: TrackID(voice.id), at: 0)
        }
        return session
    }

    static func slice(_ text: TranscriptText, _ range: Range<Int>) -> String {
        (text.string as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    static func spoken(_ text: TranscriptText, at frame: Frames) -> [String] {
        text.units(at: frame).map { slice(text, $0.text) }
    }

    /// P3. Tracks make paragraphs, and a pause on one track makes a paragraph. Each paragraph has
    /// its header, and each unit has its text range.
    @Test func paragraphsByTrackAndPause() throws {
        let session = try Self.session([
            Voice("host", "Host", [(0, 24_000, "Hello"), (24_000, 48_000, "there"), (400_000, 424_000, "Bye")]),
            Voice("guest", "Guest", [(200_000, 224_000, "Hi"), (224_000, 240_000, "Tom")]),
        ])

        let text = TranscriptText(session: session)

        #expect(text.string == "Host · 0:00:00\nHello there\nGuest · 0:00:04\nHi Tom\nHost · 0:00:08\nBye\n")
        #expect(text.headers.map(\.range) == [0..<14, 27..<42, 50..<64])
        #expect(text.headers.map(\.track) == ["host", "guest", "host"])
        #expect(text.backchannels.isEmpty)
        #expect(text.units.map(\.text) == [15..<20, 21..<26, 43..<45, 46..<49, 65..<68])
        #expect(
            text.units.map(\.frames) == [
                0..<24_000, 24_000..<48_000, 200_000..<224_000, 224_000..<240_000, 400_000..<424_000,
            ])
        #expect(text.units.map(\.track) == ["host", "host", "guest", "guest", "host"])
    }

    /// P3. A pause of 1.5 s starts a paragraph, at each sample rate; a frame less does not.
    @Test(arguments: [(48_000, 72_000, 2), (48_000, 71_999, 1), (44_100, 66_150, 2), (44_100, 66_149, 1)])
    func pauseThreshold(rate: Int, pause: Int, paragraphs: Int) throws {
        let session = try Self.session(
            rate: rate, [Voice("host", "Host", [(0, 1_000, "a"), (1_000 + pause, 2_000 + pause, "b")], rate: rate)])

        let text = TranscriptText(session: session)

        #expect(text.headers.count == paragraphs)
        if paragraphs == 1 { #expect(text.string == "Host · 0:00:00\na b\n") }
    }

    /// P3. The pause runs from the largest end of the track in the paragraph, so a long cue keeps the
    /// paragraph over the short units that start inside it.
    @Test func longCueHoldsTheParagraph() throws {
        let session = try Self.session([
            Voice("host", "Host", [(0, 300_000, "long"), (10_000, 20_000, "short"), (150_000, 160_000, "late")])
        ])

        let text = TranscriptText(session: session)

        #expect(text.string == "Host · 0:00:00\nlong short late\n")
    }

    /// P3. The header time is the timeline time of the first unit, rounded down to the second, with
    /// the hours unpadded.
    @Test func headerTimeRoundsDown() throws {
        let session = try Self.session([
            Voice(
                "host", "Host",
                [(95_952, 96_000, "a"), (2_879_952, 2_880_000, "c"), (175_752_000, 175_753_000, "b")])
        ])

        let text = TranscriptText(session: session)

        #expect(text.string == "Host · 0:00:01\na\nHost · 0:00:59\nc\nHost · 1:01:01\nb\n")
    }

    /// P3. A WebVTT cue of three tokens is one unit with one text range.
    @Test func cueIsOneUnit() throws {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nthree word cue\n\n00:00:03.500 --> 00:00:04.000\nok\n"
        let session = try Self.session([Voice("host", "Host", vtt: vtt)])

        let text = TranscriptText(session: session)

        #expect(text.string == "Host · 0:00:01\nthree word cue ok\n")
        #expect(text.units.map(\.text) == [15..<29, 30..<32])
        let cue = try #require(text.units.first)
        #expect(Self.slice(text, cue.text) == "three word cue")
    }

    /// P3 (UI council A-Q11). A short run of another track between two units of one track that the
    /// pause rule keeps together does not split the paragraph: it goes after the paragraph, as its
    /// own line with its track name.
    @Test func backchannelKeepsTheParagraph() throws {
        let session = try Self.session([
            Voice("host", "Host", [(0, 24_000, "so"), (48_000, 72_000, "right")]),
            Voice("guest", "Guest", [(30_000, 40_000, "Mm-hm.")]),
        ])

        let text = TranscriptText(session: session)

        #expect(text.string == "Host · 0:00:00\nso right\nGuest: Mm-hm.\n")
        #expect(text.headers.map(\.range) == [0..<14])
        #expect(text.backchannels == [TranscriptText.Backchannel(line: 24..<37, name: 24..<29, track: "guest")])
        #expect(text.units.map(\.text) == [15..<17, 18..<23, 31..<37])
        #expect(text.units.map(\.track) == ["host", "host", "guest"])
    }

    /// P3. A run of 47 999 frames at 48 kHz is a backchannel and a run of 48 000 frames is not. A
    /// host pause of 71 999 frames keeps the paragraph and 72 000 frames does not.
    @Test(arguments: [(47_999, 71_999, 1, 1), (48_000, 71_999, 3, 0), (47_999, 72_000, 3, 0)])
    func backchannelThreshold(guestSpan: Int, hostPause: Int, paragraphs: Int, lines: Int) throws {
        let session = try Self.session([
            Voice("host", "Host", [(0, 1_000, "a"), (1_000 + hostPause, 2_000 + hostPause, "b")]),
            Voice("guest", "Guest", [(2_000, 2_000 + guestSpan, "Mm")]),
        ])

        let text = TranscriptText(session: session)

        #expect(text.headers.count == paragraphs)
        #expect(text.backchannels.count == lines)
        if paragraphs == 3 { #expect(text.headers.map(\.track) == ["host", "guest", "host"]) }
    }

    /// P3. The line names its track, and the name range holds only the name (UTF-16 units).
    @Test func backchannelLineNamesItsTrack() throws {
        let session = try Self.session([
            Voice("host", "Host", [(0, 24_000, "so"), (48_000, 72_000, "right")]),
            Voice("guest", "Ana 🎙", [(30_000, 40_000, "Mm")]),
        ])

        let text = TranscriptText(session: session)

        #expect(text.string == "Host · 0:00:00\nso right\nAna 🎙: Mm\n")
        let line = try #require(text.backchannels.first)
        #expect(line.name == 24..<30)
        #expect(Self.slice(text, line.name) == "Ana 🎙")
        #expect(line.line == 24..<34)
        #expect(text.units.last?.text == 32..<34)
    }

    /// P3 (UI council A-Q11). Two short runs of two other tracks give two lines, in start order.
    @Test func twoBackchannelsOfTwoTracks() throws {
        let session = try Self.session([
            Voice("host", "Host", [(0, 24_000, "so"), (60_000, 84_000, "right")]),
            Voice("guest", "Guest", [(30_000, 40_000, "Mm")]),
            Voice("third", "Third", [(45_000, 50_000, "Yes")]),
        ])

        let text = TranscriptText(session: session)

        #expect(text.string == "Host · 0:00:00\nso right\nGuest: Mm\nThird: Yes\n")
        #expect(
            text.backchannels == [
                TranscriptText.Backchannel(line: 24..<33, name: 24..<29, track: "guest"),
                TranscriptText.Backchannel(line: 34..<44, name: 34..<39, track: "third"),
            ])
    }

    /// P3. When one run between two units is 1 s or more, the track rule applies to all the runs.
    @Test func oneLongRunMakesEveryRunAParagraph() throws {
        let session = try Self.session([
            Voice("host", "Host", [(0, 24_000, "so"), (60_000, 84_000, "right")]),
            Voice("guest", "Guest", [(30_000, 40_000, "Mm")]),
            Voice("third", "Third", [(45_000, 100_000, "Well")]),
        ])

        let text = TranscriptText(session: session)

        #expect(
            text.string
                == "Host · 0:00:00\nso\nGuest · 0:00:00\nMm\nThird · 0:00:00\nWell\nHost · 0:00:01\nright\n")
        #expect(text.backchannels.isEmpty)
    }

    /// P3. After a ripple delete the cut units go and the later headers move.
    @Test func textFollowsAnEdit() throws {
        var session = try Self.session([
            Voice("host", "Host", [(0, 24_000, "one"), (24_000, 48_000, "two"), (480_000, 504_000, "three")])
        ])
        #expect(TranscriptText(session: session).string == "Host · 0:00:00\none two\nHost · 0:00:10\nthree\n")

        try session.rippleDelete(0..<48_000, on: ["host"])

        let text = TranscriptText(session: session)
        #expect(text.string == "Host · 0:00:09\nthree\n")
        #expect(text.units.map(\.frames) == [432_000..<456_000])
    }

    /// P4. The start frame is in the unit and the end frame is not. Two overlapping units of two
    /// tracks both hold a frame, a gap holds none, and a unit of a backchannel line gives its text
    /// range in that line. A long cue holds a frame after the short units that start inside it.
    @Test func unitAtAFrame() throws {
        let overlap = TranscriptText(
            session: try Self.session([
                Voice("host", "Host", [(48_000, 96_000, "a")]), Voice("guest", "Guest", [(72_000, 120_000, "b")]),
            ]))
        let expected: [(Int, [String])] = [
            (47_999, []), (48_000, ["a"]), (71_999, ["a"]), (72_000, ["a", "b"]), (95_999, ["a", "b"]),
            (96_000, ["b"]), (119_999, ["b"]), (120_000, []),
        ]
        for (frame, texts) in expected {
            #expect(Self.spoken(overlap, at: Frames(frame)) == texts, "at frame \(frame)")
        }

        let backchannel = TranscriptText(
            session: try Self.session([
                Voice("host", "Host", [(0, 24_000, "so"), (48_000, 72_000, "right")]),
                Voice("guest", "Guest", [(30_000, 40_000, "Mm-hm.")]),
            ]))
        let line = try #require(backchannel.units(at: 35_000).first)
        #expect(backchannel.units(at: 35_000).count == 1)
        #expect(line.text == 31..<37)
        #expect(line.track == "guest")
        #expect(Self.spoken(backchannel, at: 60_000) == ["right"])

        let long = TranscriptText(
            session: try Self.session([
                Voice(
                    "host", "Host",
                    [
                        (0, 1_000_000, "long"), (100_000, 110_000, "s1"), (200_000, 210_000, "s2"),
                        (300_000, 310_000, "s3"),
                    ])
            ]))
        #expect(Self.spoken(long, at: 105_000) == ["long", "s1"])
        #expect(Self.spoken(long, at: 500_000) == ["long"])
        #expect(Self.spoken(long, at: 999_999) == ["long"])
        #expect(Self.spoken(long, at: 1_000_000) == [])
    }
}
