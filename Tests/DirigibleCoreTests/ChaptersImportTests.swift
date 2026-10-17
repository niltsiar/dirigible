import Foundation
import Testing

@testable import DirigibleCore

/// The chapters import (run 2026-10-17-agent-pack, C20 to C25): the parse of a Podcasting 2.0 JSON
/// Chapters file, and `Session.importChapters`.
struct ChaptersImportTests {
    static let imageA = try! ArtworkName("0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.jpg")
    static let imageB = try! ArtworkName("1C4D6C3F-7A2B-4E3C-8F68-2D9A3B0E5F71.png")

    static func file(_ chapters: String, version: String = "1.2.0") throws -> ImportedChapters {
        try ImportedChapters(data: Data(#"{"version": "\#(version)", "chapters": [\#(chapters)]}"#.utf8))
    }

    /// A session with chapters (and plain markers) at the given frames.
    static func session(rate: Int = 48_000, _ markers: [Marker]) throws -> Session {
        var session = Session(sampleRate: rate)
        for marker in markers { try session.setMarker(marker) }
        return session
    }

    /// The markers by position, with the IDs left out: an import makes new IDs.
    static func shape(_ session: Session) -> [String] {
        session.sortedMarkers.map { "\($0.name)@\($0.position)\($0.image.map { " " + $0.name } ?? "")" }
    }

    /// C22: each fault of the file, with the place of the chapter. Control: a file with no fault
    /// parses (the test after this one).
    @Test(arguments: [
        ("not json", ChaptersFileError.notAnObject),
        ("[1, 2]", .notAnObject),
        (#"{"version": "1.2.0"}"#, .noChapters),
        (#"{"version": "1.2.0", "chapters": []}"#, .noChapters),
        (#"{"version": "1.2.0", "chapters": "x"}"#, .noChapters),
        (#"{"version": "2.0.0", "chapters": [{"startTime": 0}]}"#, .unsupportedVersion("2.0.0")),
        (#"{"chapters": [{"startTime": 0}]}"#, .unsupportedVersion(nil)),
        (#"{"version": "1.0.0", "chapters": [{"startTime": 0}, {"title": "B"}]}"#, .startTime(place: 2)),
        (#"{"version": "1.0.0", "chapters": [{"startTime": -1}]}"#, .startTime(place: 1)),
        (#"{"version": "1.0.0", "chapters": [{"startTime": "5"}]}"#, .startTime(place: 1)),
        (#"{"version": "1.0.0", "chapters": [{"startTime": true}]}"#, .startTime(place: 1)),
        (#"{"version": "1.0.0", "chapters": [{"startTime": 1e999}]}"#, .startTime(place: 1)),
        (#"{"version": "1.0.0", "chapters": [{"startTime": 0}, 5]}"#, .startTime(place: 2)),
        (#"{"version": "1.0.0", "chapters": [{"startTime": 0, "title": "A\u0001B"}]}"#, .title(place: 1)),
        (
            #"{"version": "1.0.0", "chapters": [{"startTime": 0}, {"startTime": 1, "title": "A\u001BB"}]}"#,
            .title(place: 2)
        ),
    ])
    func aBadChaptersFileIsRefused(json: String, error: ChaptersFileError) {
        #expect(throws: error) { try ImportedChapters(data: Data(json.utf8)) }
    }

    /// C22 frames: the frame of a chapter is checked before `Int(...)`. 2^40 frames at 48 kHz are
    /// 22,906,492.245 s. A bad import changes nothing.
    @Test func aChapterPastTheFrameLimitChangesNothing() throws {
        var session = try Self.session([Marker(id: "m", name: "Old", position: 100, kind: .chapter)])
        let before = session
        let huge = try Self.file(#"{"startTime": 0}, {"startTime": 1e300}"#)
        #expect(throws: SessionError.chapterOutOfRange(place: 2)) {
            try session.importChapters(huge, at: 0, replacing: false)
        }
        let past = try Self.file(#"{"startTime": 22906492.25}"#)
        #expect(throws: SessionError.chapterOutOfRange(place: 1)) {
            try session.importChapters(past, at: 0, replacing: true)
        }
        let late = try Self.file(#"{"startTime": 1}"#)
        #expect(throws: SessionError.chapterOutOfRange(place: 1)) {
            try session.importChapters(late, at: Frames.limit, replacing: false)
        }
        #expect(throws: SessionError.frameOutOfRange) {
            try session.importChapters(late, at: Frames(Frames.limit.count + 1), replacing: false)
        }
        #expect(throws: SessionError.frameOutOfRange) { try session.importChapters(late, at: -1, replacing: false) }
        #expect(session == before)

        let last = try Self.file(#"{"startTime": 22906492.24}"#)
        let ids = try session.importChapters(last, at: 0, replacing: false).markers
        let first = try #require(ids.first)
        #expect(session.markers[first]?.position == 1_099_511_627_520, "the frame just under the limit")
    }

    /// C20: chapters at 0, 94.5, and 168 s at 48 kHz, from `at` 0 and from `at` 240000.
    @Test func aChaptersImportAddsChapterMarkers() throws {
        let file = try Self.file(
            #"{"startTime": 0, "title": "Intro"}, {"startTime": 94.5, "title": "Talk"}, {"startTime": 168, "title": "End"}"#
        )
        for (at, expected) in [(0, [0, 4_536_000, 8_064_000]), (240_000, [240_000, 4_776_000, 8_304_000])] {
            var session = Session(sampleRate: 48_000)
            let ids = try session.importChapters(file, at: Frames(at), replacing: false).markers
            #expect(ids.count == 3 && Set(ids).count == 3)
            let markers = ids.compactMap { session.markers[$0] }
            #expect(markers.map(\.position) == expected.map { Frames($0) })
            #expect(markers.map(\.name) == ["Intro", "Talk", "End"] && markers.allSatisfy { $0.kind == .chapter })
        }
    }

    /// C23: no title, `toc` false, a link that stays, a link that goes, and an `img` with no copy.
    @Test func aChaptersImportMapsTheOptionalFields() throws {
        let file = try Self.file(
            """
            {"startTime": 0},
            {"startTime": 5.5, "title": "Rock", "toc": false},
            {"startTime": 10, "title": "Sponsor", "url": "https://example.com/s", "img": "s.jpg"},
            {"startTime": 20, "title": "Mail", "url": "mailto:a@b.c"},
            {"startTime": 30, "title": "  ", "img": "x.png"}
            """)
        var session = Session(sampleRate: 48_000)
        let report = try session.importChapters(file, at: 0, replacing: false)
        let markers = report.markers.compactMap { session.markers[$0] }
        #expect(markers.map(\.name) == ["Chapter 1", "Rock", "Sponsor", "Mail", "Chapter 5"])
        #expect(markers.map(\.kind) == [.chapter, .marker, .chapter, .chapter, .chapter])
        #expect(markers.map(\.position) == [0, 264_000, 480_000, 960_000, 1_440_000])
        #expect(markers.map { $0.url?.text } == [nil, nil, "https://example.com/s", nil, nil])
        #expect(file.droppedURLs == [4])
        #expect(markers.allSatisfy { $0.image == nil }, "the import copies no image")
        #expect(report.imagesLeft == 2, "the chapters 3 and 5 name an img")
    }

    /// C24: `replace` removes the chapters and keeps the plain markers; with no `replace`, the old
    /// chapters stay.
    @Test func aChaptersImportWithReplaceKeepsPlainMarkers() throws {
        let base = try Self.session([
            Marker(id: "old", name: "Old", position: 48_000, kind: .chapter),
            Marker(id: "note", name: "Note", position: 96_000, kind: .marker),
        ])
        let file = try Self.file(#"{"startTime": 3, "title": "New"}"#)
        var replaced = base
        try replaced.importChapters(file, at: 0, replacing: true)
        #expect(Self.shape(replaced) == ["Note@96000", "New@144000"])
        var added = base
        try added.importChapters(file, at: 0, replacing: false)
        #expect(Self.shape(added) == ["Old@48000", "Note@96000", "New@144000"])
    }

    /// C24b: a removed image moves to the file chapter at its millisecond, 20 frames off here, and
    /// with `at` the time counts from `at`.
    @Test func aChaptersImportWithReplaceKeepsEachImageAtItsTime() throws {
        let base = try Self.session([
            Marker(id: "a", name: "A", position: 480_020, kind: .chapter, image: Self.imageA),
            Marker(id: "b", name: "B", position: 960_000, kind: .chapter, image: Self.imageB),
            Marker(id: "c", name: "C", position: 1_440_000, kind: .chapter),
        ])
        let file = try Self.file(
            #"{"startTime": 0, "title": "Intro"}, {"startTime": 10, "title": "Ten"}, {"startTime": 20, "title": "Twenty"}"#
        )
        var session = base
        let report = try session.importChapters(file, at: 0, replacing: true)
        let images = report.markers.compactMap { session.markers[$0] }.map(\.image)
        #expect(images == [nil, Self.imageA, Self.imageB])
        #expect(session.markers.count == 3 && session.markers["a"] == nil, "the old chapters are gone")
        #expect(report.imagesLeft == 0)

        var later = base
        let shifted = try later.importChapters(file, at: 480_000, replacing: true)
        let moved = shifted.markers.compactMap { later.markers[$0] }
        #expect(moved.map(\.position) == [480_000, 960_000, 1_440_000])
        #expect(moved.map(\.image) == [Self.imageA, Self.imageB, nil], "20 frames after at is the millisecond 0")
    }

    /// C24b: a removed image with no chapter at its time stops the import before any change. With
    /// no `replace`, nothing is removed, so the import goes on. A second image at one millisecond
    /// has no chapter of its own.
    @Test func aChaptersImportThatWouldDropAnImageChangesNothing() throws {
        let outro = Marker(id: "o", name: "Outro", position: 576_000, kind: .chapter, image: Self.imageA)
        let base = try Self.session([Marker(id: "i", name: "Intro", position: 0, kind: .chapter), outro])
        let file = try Self.file(#"{"startTime": 0, "title": "Start"}, {"startTime": 13, "title": "End"}"#)
        var session = base
        #expect(throws: SessionError.chapterImageNotKept([outro])) {
            try session.importChapters(file, at: 0, replacing: true)
        }
        #expect(session == base)

        try session.importChapters(file, at: 0, replacing: false)
        #expect(session.markers["o"] == outro && session.markers.count == 4, "no replace: the image stays")

        let twin = Marker(id: "t", name: "Twin", position: 576_010, kind: .chapter, image: Self.imageB)
        var pair = try Self.session([outro, twin])
        let one = try Self.file(#"{"startTime": 12, "title": "Only"}"#)
        #expect(throws: SessionError.chapterImageNotKept([twin])) {
            try pair.importChapters(one, at: 0, replacing: true)
        }
        let before = try Self.session([
            Marker(id: "x", name: "Before", position: 10, kind: .chapter, image: Self.imageA)
        ])
        var early = before
        #expect(throws: SessionError.chapterImageNotKept(before.sortedMarkers)) {
            try early.importChapters(try Self.file(#"{"startTime": 0}"#), at: 48_000, replacing: true)
        }
    }

    /// Code gate 1 item 2: with `replace`, a removed image goes only to a chapter, because the
    /// export writes no image of a plain marker. A `toc` false entry alone at the millisecond of
    /// the image refuses the import; a chapter after it at the same millisecond takes the image.
    @Test func aChaptersImportWithReplaceGivesAnImageOnlyToAChapter() throws {
        let outro = Marker(id: "o", name: "Outro", position: 480_000, kind: .chapter, image: Self.imageA)
        let base = try Self.session([outro])
        var session = base
        let plain = try Self.file(
            #"{"startTime": 0, "title": "Start"}, {"startTime": 10, "title": "Ad", "toc": false}"#)
        #expect(throws: SessionError.chapterImageNotKept([outro])) {
            try session.importChapters(plain, at: 0, replacing: true)
        }
        #expect(session == base)

        let both = try Self.file(#"{"startTime": 10, "title": "Ad", "toc": false}, {"startTime": 10, "title": "End"}"#)
        let ids = try session.importChapters(both, at: 0, replacing: true).markers
        let markers = ids.compactMap { session.markers[$0] }
        #expect(markers.map(\.kind) == [.marker, .chapter])
        #expect(markers.map(\.image) == [nil, Self.imageA], "the chapter after the plain marker takes the image")
    }

    /// Code gate 1 item 2: a second import with `replace` of one file gives the session of the
    /// first. A `toc` false entry that matches a plain marker by name and frame adds no marker and
    /// gives the ID of that marker; two equal entries match two markers.
    @Test func twoChaptersImportsWithReplaceGiveTheSessionOfOne() throws {
        let base = try Self.session([
            Marker(id: "a", name: "A", position: 480_000, kind: .chapter, image: Self.imageA),
            Marker(id: "n", name: "Note", position: 100, kind: .marker),
        ])
        let file = try Self.file(
            #"{"startTime": 0, "title": "Intro"}, {"startTime": 5, "title": "Ad", "toc": false}, "#
                + #"{"startTime": 5, "title": "Ad", "toc": false}, {"startTime": 10, "title": "Talk"}"#)
        func shape(_ session: Session) -> [String] {
            session.sortedMarkers.map { "\($0.name)@\($0.position) \($0.kind.rawValue) \($0.image?.name ?? "-")" }
                .sorted()
        }
        var once = base
        let first = try once.importChapters(file, at: 0, replacing: true).markers
        var twice = once
        let second = try twice.importChapters(file, at: 0, replacing: true).markers

        #expect(
            shape(once) == [
                "Ad@240000 marker -", "Ad@240000 marker -", "Intro@0 chapter -", "Note@100 marker -",
                "Talk@480000 chapter \(Self.imageA.name)",
            ], "\(shape(once))")
        #expect(shape(twice) == shape(once), "\(shape(twice))")
        #expect(second.count == 4 && Set(second[1...2]) == Set(first[1...2]), "the plain markers keep their IDs")
    }

    /// Code gate 1 item 5: a title loses the spaces and line breaks at its edges, and each inner
    /// tab, LF, and CR becomes one space. Another control character still refuses the file.
    @Test func aChaptersImportMapsLineBreaksInATitleToSpaces() throws {
        let file = try Self.file(#"{"startTime": 0, "title": " A\tB\nC\r "}, {"startTime": 1, "title": "\r\nEnd\n"}"#)
        #expect(file.chapters.map(\.title) == ["A B C", "End"])
        #expect(throws: ChaptersFileError.title(place: 1)) { try Self.file(#"{"startTime": 0, "title": "A\u0007B"}"#) }
    }

    /// C25: the export, then the import, keeps the millisecond. 1.234 s at 44.1 kHz is the frame
    /// 54,419. The sweep keeps each chapter within 23 frames, half a millisecond.
    @Test func aChaptersRoundTripKeepsTheMillisecond() throws {
        var source = Session(sampleRate: 44_100)
        try source.setMarker(Marker(id: "m", name: "Part", position: 54_419, kind: .chapter))
        let one = try ImportedChapters(data: source.chaptersJSON(in: 0..<100_000, imageStem: "x"))
        var target = Session(sampleRate: 44_100)
        let first = try #require(try target.importChapters(one, at: 0, replacing: false).markers.first)
        #expect(target.markers[first]?.position == 54_419)

        var sweep = Session(sampleRate: 44_100)
        let frames = (1...200).map { Frames($0 * 44_201 + $0 * 7_919 % 1_000) }
        for (index, frame) in frames.enumerated() {
            try sweep.setMarker(Marker(id: MarkerID("m\(index)"), name: "C\(index)", position: frame, kind: .chapter))
        }
        let file = try ImportedChapters(data: sweep.chaptersJSON(in: 0..<Frames(10_000_000), imageStem: "x"))
        var back = Session(sampleRate: 44_100)
        let ids = try back.importChapters(file, at: 0, replacing: false).markers
        let off = zip(ids, frames).map { abs((back.markers[$0]?.position.count ?? -99_999) - $1.count) }
        #expect(off.count == 200 && off.allSatisfy { $0 <= 23 }, "largest difference \(off.max() ?? -1)")
    }

    /// C25: an export from frame 240000 and an import with `replace` at 240000 keep each image on
    /// its chapter.
    @Test func anExportAndAnImportWithReplaceKeepEachImage() throws {
        var session = try Self.session([
            Marker(id: "a", name: "A", position: 480_000, kind: .chapter, image: Self.imageA),
            Marker(id: "b", name: "B", position: 576_000, kind: .chapter, image: Self.imageB),
            Marker(id: "c", name: "C", position: 720_000, kind: .chapter),
        ])
        let before = Self.shape(session)
        let json = try session.chaptersJSON(in: 240_000..<1_000_000, imageStem: "show")
        let file = try ImportedChapters(data: json)
        let report = try session.importChapters(file, at: 240_000, replacing: true)
        #expect(Self.shape(session) == before, "the names, the frames, and the images")
        #expect(report.imagesLeft == 0, "the file names two img, and both stay")
    }
}
