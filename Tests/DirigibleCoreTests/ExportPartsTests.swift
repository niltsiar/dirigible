import Foundation
import Testing

@testable import DirigibleCore

/// The parts of an export range at the chapters or the markers, and their file names (run
/// 2026-10-28-chapter-export-files, criteria C1 to C4 and the C7 rule).
struct ExportPartsTests {
    static let end: Frames = 1_440_000
    static let limit = 209

    static func session(_ markers: [(String, Frames, Marker.Kind)], title: String? = nil) throws -> Session {
        var session = Session(sampleRate: 48_000)
        for (name, position, kind) in markers {
            try session.setMarker(Marker(id: MarkerID(name), name: name, position: position, kind: kind))
        }
        if let title {
            var episode = Episode()
            episode.title = try EpisodeLine(title)
            session.setEpisode(episode)
        }
        return session
    }

    static func chapters(_ points: [(String, Frames)], title: String? = nil) throws -> Session {
        try session(points.map { ($0.0, $0.1, .chapter) }, title: title)
    }

    static func ranges(_ parts: ExportParts) -> [Range<Frames>] { parts.parts.map(\.range) }

    static func length(_ range: Range<Frames>) -> Int { (range.upperBound - range.lowerBound).count }

    static func names(_ parts: ExportParts, stem: String = "Ep 12", ext: String = "mp3") -> [String] {
        parts.parts.map {
            Session.partFileName($0, digits: parts.digits, stem: stem, pathExtension: ext, limit: limit)
        }
    }

    /// C1 case 4. Control: no millisecond rule gives a part of 0 frames for "c".
    @Test func twoChaptersAtOneFrameGiveOnePart() throws {
        let session = try Self.chapters([("b", 480_000), ("c", 480_000)])
        let parts = session.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro")
        #expect(Self.ranges(parts) == [0..<480_000, 480_000..<Self.end])
        #expect(parts.parts.map(\.start) == [.rangeStart, .point(session.markers[MarkerID("b")]!, number: 1)])
        #expect(parts.dropped.map(\.id) == [MarkerID("c")])
        // 480000 and 480023 round to 10000 ms.
        let near = try Self.chapters([("b", 480_000), ("c", 480_023)])
        let nearParts = near.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro")
        #expect(Self.ranges(nearParts) == [0..<480_000, 480_000..<Self.end])
        #expect(nearParts.dropped.map(\.id) == [MarkerID("c")])
    }

    /// C1 case 4: the rule compares rounded milliseconds, not a distance.
    @Test(arguments: [(480_000, 480_024, 24), (480_023, 480_024, 1)])
    func pointsOneFrameApartAcrossAMillisecondGiveAOneFramePart(first: Int, second: Int, length: Int) throws {
        let session = try Self.chapters([("b", Frames(first)), ("c", Frames(second))])
        let parts = session.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro")
        #expect(parts.parts.count == 3)
        #expect(parts.parts[1].range == Frames(first)..<Frames(second))
        #expect(Self.length(parts.parts[1].range) == length)
        #expect(parts.dropped.isEmpty)
    }

    /// C1 case 1.
    @Test func aChapterAtTheStartGivesNoEmptyPart() throws {
        let session = try Self.chapters([("a", 0), ("b", 480_000), ("c", 960_000)])
        let parts = session.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro")
        #expect(Self.ranges(parts) == [0..<480_000, 480_000..<960_000, 960_000..<Self.end])
        #expect(parts.parts.map(\.title?.text) == ["a", "b", "c"])
    }

    /// C1 case 2. Control: no part before the first point loses 5 s.
    @Test func audioBeforeTheFirstChapterIsPartZero() throws {
        let session = try Self.chapters([("a", 240_000), ("b", 720_000)])
        let parts = session.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro")
        #expect(Self.ranges(parts) == [0..<240_000, 240_000..<720_000, 720_000..<Self.end])
        #expect(parts.parts.first?.start == .rangeStart)
    }

    /// C1 case 3 and the chapters at or past the end, which give no part.
    @Test func theLastPartEndsAtTheRangeEnd() throws {
        let session = try Self.chapters([("a", 0), ("b", 960_000), ("at-end", Self.end), ("past", Self.end + 48_000)])
        let parts = session.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro")
        #expect(Self.ranges(parts) == [0..<960_000, 960_000..<Self.end])
        #expect(parts.dropped.isEmpty)
    }

    /// C1 case 5: a point at the rounded millisecond of the end has no length and is dropped.
    @Test(
        arguments: [
            (1_440_000, 10, nil), (1_440_000, 24, nil), (1_440_000, 25, 25), (1_440_024, 1, 1),
        ] as [(Int, Int, Int?)])
    func aChapterAtTheMillisecondOfTheEndIsDropped(end: Int, before: Int, length: Int?) throws {
        let session = try Self.chapters([("a", 0), ("late", Frames(end - before))])
        let parts = session.exportParts(in: 0..<Frames(end), by: .chapters, introTitle: "Intro")
        if let length {
            #expect(parts.parts.count == 2)
            #expect(parts.parts.last.map { Self.length($0.range) } == length)
            #expect(parts.dropped.isEmpty)
        } else {
            #expect(Self.ranges(parts) == [0..<Frames(end)])
            #expect(parts.dropped.map(\.id) == [MarkerID("late")])
        }
    }

    /// C2.
    @Test func aMarkersSplitTakesBothKinds() throws {
        let session = try Self.session([("plain", 336_000, .marker), ("chapter", 720_000, .chapter)])
        let chapters = session.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro")
        #expect(Self.ranges(chapters) == [0..<720_000, 720_000..<Self.end])
        let markers = session.exportParts(in: 0..<Self.end, by: .markers, introTitle: "Intro")
        #expect(Self.ranges(markers) == [0..<336_000, 336_000..<720_000, 720_000..<Self.end])
    }

    /// C3: the part before the first split point of a selection.
    @Test func theFirstPartOfASelectionTakesTheChapterBeforeIt() throws {
        let session = try Self.chapters([("Five", 240_000), ("Fifteen", 720_000)], title: "Episode 12")
        let parts = session.exportParts(in: 384_000..<Self.end, by: .chapters, introTitle: "Intro")
        #expect(Self.ranges(parts) == [384_000..<720_000, 720_000..<Self.end])
        #expect(parts.parts.map(\.title?.text) == ["Five", "Fifteen"])
        #expect(parts.parts.first?.start == .rangeStart)
        // No point before the range start: the episode title, else the show, else introTitle.
        let titled = session.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro")
        #expect(titled.parts.first?.title?.text == "Episode 12")
        var show = try Self.chapters([("Five", 240_000)])
        var episode = Episode()
        episode.show = try EpisodeLine("The Show")
        show.setEpisode(episode)
        #expect(
            show.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro").parts.first?.title?.text
                == "The Show")
        let bare = try Self.chapters([("Five", 240_000)])
        #expect(
            bare.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro").parts.first?.title?.text == "Intro")
    }

    /// C3: the line breaks that `setMarker` stores. Fail: a throw, or a line break in the title.
    @Test(arguments: ["A\u{2028}B", "A\u{2029}B", "A\u{85}B"])
    func aNewlineInANameIsASpace(name: String) throws {
        var session = Session(sampleRate: 48_000)
        try session.setMarker(Marker(id: MarkerID("m"), name: name, position: 0, kind: .chapter))
        let parts = session.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro")
        #expect(parts.parts.map(\.title?.text) == ["A B"])
    }

    /// The C7 rule: a part session has the part title, and a nil title keeps the episode title.
    @Test func aPartSessionHasThePartTitle() throws {
        let untitled = try Self.chapters([("Interview", 0)])
        let part = try #require(untitled.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro").parts.first)
        #expect(untitled.forPart(part).episode.title?.text == "Interview")
        let titled = try Self.chapters([("   ", 0)], title: "Episode 12")
        let blank = try #require(titled.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro").parts.first)
        #expect(blank.title == nil)
        #expect(titled.forPart(blank).episode.title?.text == "Episode 12")
        #expect(titled.forPart(blank) == titled)
    }

    /// C4. Control: numbers from 0 give `Ep 12-00-Intro.mp3`.
    @Test func fileNamesFollowTheAudacityRule() throws {
        let session = try Self.chapters([("Intro", 0), ("Talk", 480_000)])
        #expect(
            Self.names(session.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro"))
                == ["Ep 12-01-Intro.mp3", "Ep 12-02-Talk.mp3"])
        let late = try Self.chapters([("Intro", 240_000), ("Talk", 480_000)], title: "Episode 12")
        #expect(
            Self.names(late.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro"))
                == ["Ep 12-00-Episode 12.mp3", "Ep 12-01-Intro.mp3", "Ep 12-02-Talk.mp3"])
    }

    /// C4: the spaces at each end and a leading dot go; a title that is then empty gives no title.
    @Test(arguments: [(" Talk ", "Ep 12-01-Talk.mp3"), (".hidden", "Ep 12-01-hidden.mp3"), ("..", "Ep 12-01.mp3")])
    func aTitleLosesItsEndSpacesAndALeadingDot(name: String, file: String) throws {
        let session = try Self.chapters([(name, 0)])
        #expect(Self.names(session.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro")) == [file])
    }

    /// C4, U19. Control: a rule that replaces only `/` and `:` fails the other arguments.
    @Test(arguments: ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\u{7F}", "\u{9F}"])
    func eachCharacterThatAVolumeRefusesBecomesADash(character: String) throws {
        let session = try Self.chapters([("a\(character)b", 0)])
        #expect(
            Self.names(session.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro")) == [
                "Ep 12-01-a-b.mp3"
            ])
    }

    /// C4 byte limit. Control: no byte cut gives a name of 314 bytes.
    @Test func aLongTitleIsCutOnACharacterBoundary() throws {
        let session = try Self.chapters([(String(repeating: "é", count: 150), 0)])
        let name = try #require(
            Self.names(session.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro")).first)
        #expect(name.utf8.count <= Self.limit)
        #expect(name.utf8.count >= Self.limit - 1)
        #expect(name.dropFirst(9).dropLast(4).allSatisfy { $0 == "é" })
        #expect(name.hasPrefix("Ep 12-01-é"))
        #expect(name.hasSuffix("é.mp3"))
    }

    /// C4 byte limit, H3. Control: a cut at the end of the name removes `-01` and gives two parts one name.
    @Test func aLongStemIsCutAfterTheTitle() throws {
        let session = try Self.chapters([("Intro", 0), ("Talk", 480_000)])
        let stem = String(repeating: "s", count: 250)
        let names = Self.names(session.exportParts(in: 0..<Self.end, by: .chapters, introTitle: "Intro"), stem: stem)
        #expect(names.allSatisfy { $0.utf8.count <= Self.limit })
        #expect(names[0].hasSuffix("s-01.mp3"))
        #expect(names[1].hasSuffix("s-02.mp3"))
        #expect(Set(names).count == 2)
    }

    /// C4 digits: 1 to 100 give `001` to `100`.
    @Test func aHundredPartsHaveThreeDigits() throws {
        let session = try Self.chapters((0..<100).map { ("c\($0)", Frames($0 * 48_000)) })
        let parts = session.exportParts(in: 0..<Frames(100 * 48_000), by: .chapters, introTitle: "Intro")
        let names = Self.names(parts)
        #expect(names.count == 100)
        #expect(names.first == "Ep 12-001-c0.mp3")
        #expect(names.last == "Ep 12-100-c99.mp3")
    }

    /// C4 digits: 0 to 99 give `00` to `99`.
    @Test func aHundredPartsFromZeroHaveTwoDigits() throws {
        let session = try Self.chapters((1..<100).map { ("c\($0)", Frames($0 * 48_000)) }, title: "E")
        let names = Self.names(session.exportParts(in: 0..<Frames(100 * 48_000), by: .chapters, introTitle: "Intro"))
        #expect(names.count == 100)
        #expect(names.first == "Ep 12-00-E.mp3")
        #expect(names.last == "Ep 12-99-c99.mp3")
    }

    /// C15 old files: the names of an older set of the stem, and no other name.
    @Test(arguments: [
        ("Ep 12-05-Outro.mp3", true), ("Ep 12-05.mp3", true), ("Ep 12-100-Talk.mp3", true),
        ("Ep 12.mp3", false), ("Ep 13-01-A.mp3", false), ("Ep 12-05-Outro.m4a", false), ("Ep 12-5-Outro.mp3", false),
        ("Ep 12-xx-Outro.mp3", false), ("Ep 12-05-.mp3", false), ("Ep 12 extra-05-A.mp3", false),
    ])
    func aNameOfTheStemPatternMatchesOnlyPartNames(name: String, matches: Bool) {
        #expect(Session.isPartFileName(name, stem: "Ep 12", pathExtension: "mp3") == matches)
    }
}
