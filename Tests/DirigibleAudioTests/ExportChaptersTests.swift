import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The chapter list of the M4A chapter track (run 2026-10-11-chapters-in-file, criteria C5,
/// C5f, C5g, and plan gate G12).
struct ExportChaptersTests {
    static func session(rate: Int, _ chapters: [(String, Frames)], episode: Episode = Episode()) throws -> Session {
        var session = Session(sampleRate: rate)
        for (name, position) in chapters {
            try session.setMarker(Marker(id: MarkerID(name), name: name, position: position, kind: .chapter))
        }
        session.setEpisode(episode)
        return session
    }

    /// The M4A list of the range 0..<3 s, with an output of `frames` frames at 44.1 kHz.
    static func list(_ session: Session, frames: Int = 132_300) -> M4AChapters {
        let range = 0..<Frames(3 * session.sampleRate)
        return m4aChapters(
            session.chapterList(in: range), in: session, range: range, outputRate: 44_100, outputFrames: frames,
            introTitle: "Start", images: [:])
    }

    /// C5g. The added chapter takes the episode title, else the show name, else the intro title.
    @Test func aLateFirstChapterGetsAChapterAtTheStart() throws {
        var episode = Episode()
        episode.show = try EpisodeLine("Show")
        episode.title = try EpisodeLine("Ep")
        let late = [("One", Frames(44_100)), ("Two", Frames(88_200))]
        let titled = Self.list(try Self.session(rate: 44_100, late, episode: episode)).chapters
        #expect(titled.map(\.title) == ["Ep", "One", "Two"], "titles \(titled.map(\.title))")
        #expect(titled.map(\.start) == [0, 44_100, 88_200], "starts \(titled.map(\.start))")
        episode.title = nil
        let show = Self.list(try Self.session(rate: 44_100, late, episode: episode)).chapters
        #expect(show.first?.title == "Show", "with no title: \(show.map(\.title))")
        let none = Self.list(try Self.session(rate: 44_100, late)).chapters
        #expect(none.first?.title == "Start", "with no title and no show: \(none.map(\.title))")
        let atStart = Self.list(try Self.session(rate: 44_100, [("One", 0), ("Two", 44_100)], episode: episode))
        #expect(atStart.chapters.map(\.title) == ["One", "Two"], "a first chapter at 0 adds none")
    }

    /// C5, G12. Offsets 215 and 216 at 48 kHz are 4 ms and 5 ms, so the core list keeps both, but both
    /// are frame 198 at 44.1 kHz. A chapter at or after the output end leaves the list: "d" is frame
    /// 132208 and "e" is frame 132254 at 44.1 kHz.
    @Test func theListConvertsFirstThenDrops() throws {
        let session = try Self.session(
            rate: 48_000, [("a", 0), ("b", 215), ("c", 216), ("d", 143_900), ("e", 143_950)])
        for frames in [132_254, 132_209] {
            let list = Self.list(session, frames: frames)
            #expect(list.chapters.map(\.title) == ["a", "b", "d"], "kept \(list.chapters.map(\.title)) of \(frames)")
            #expect(list.chapters.map(\.start) == [0, 198, 132_208], "starts \(list.chapters.map(\.start))")
            #expect(list.dropped.map(\.id) == ["c", "e"], "dropped \(list.dropped.map(\.id)) of \(frames)")
        }
        let late = Self.list(try Self.session(rate: 48_000, [("one", 1)]))
        #expect(late.chapters.map(\.start) == [0, 1], "offset 1 at 48 kHz is frame 1 at 44.1 kHz, after 0")
    }

    /// G1. Half up with integer math.
    @Test(arguments: [(72_000, 66_150), (120_003, 110_253), (1, 1), (0, 0), (2_176, 1_999)])
    func aStartConvertsToTheOutputRate(offset: Int, expected: Int) {
        #expect(outputFrames(Frames(offset), sessionRate: 48_000, outputRate: 44_100) == expected)
    }

    /// C5b, G4. One artwork sample spans each run of chapters with no image.
    @Test func eachRunOfChaptersWithNoImageIsOneArtworkSample() {
        let (x, y, art) = (Data([1]), Data([2]), Data([3]))
        let chapters = [
            ExportChapter(title: "a", start: 0, image: x), ExportChapter(title: "b", start: 10, image: nil),
            ExportChapter(title: "c", start: 20, image: nil), ExportChapter(title: "d", start: 30, image: y),
        ]
        let filled = imageSamples(chapters, artwork: art)
        #expect(filled.samples.map(\.start) == [0, 10, 30] && filled.samples.map(\.jpeg) == [x, art, y])
        #expect(!filled.omitted)
        let none = imageSamples(chapters, artwork: nil)
        #expect(none.samples.isEmpty && none.omitted, "no artwork: no image track, and the flag")
        let plain = imageSamples(
            chapters.map { ExportChapter(title: $0.title, start: $0.start, image: nil) }, artwork: art)
        #expect(plain.samples.isEmpty && !plain.omitted, "no chapter image: no image track")
    }
}
