import Foundation
import Testing

@testable import DirigibleCore

/// The Podcasting 2.0 JSON Chapters 1.2.0 file of the chapter markers in a range (run
/// 2026-10-09-chapters-export, criteria C1 to C8).
struct ChaptersTests {
    /// The chapters of the JSON as plain objects, through `JSONSerialization`.
    static func chapters(_ data: Data) throws -> [[String: Any]] {
        let file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(file["chapters"] as? [[String: Any]])
    }

    static func startTimes(_ data: Data) throws -> [Double] {
        try chapters(data).map { try #require($0["startTime"] as? Double) }
    }

    static func session(rate: Int = 48_000, _ markers: [(String, Frames, Marker.Kind)]) throws -> Session {
        var session = Session(sampleRate: rate)
        for (name, position, kind) in markers {
            try session.setMarker(Marker(id: MarkerID(name), name: name, position: position, kind: kind))
        }
        return session
    }

    /// C1, C2. Control: no subtraction of the range start gives 10, not 0.
    @Test func rangeStartIsTimeZero() throws {
        let n: Frames = 480_000
        let session = try Self.session([
            ("at-start", n, .chapter), ("later", n + 96_000, .chapter), ("before", n - 1, .chapter),
            ("last", 1_439_975, .chapter), ("upper", 1_440_000, .chapter), ("plain", n + 48_000, .marker),
        ])
        #expect(try Self.startTimes(session.chaptersJSON(in: n..<1_440_000, imageStem: "")) == [0, 2, 19.999])
    }

    /// C3. Half up at the millisecond: 24 frames at 48 kHz are 0.5 ms.
    @Test(arguments: [
        (48_000, 24, 0.001), (48_000, 23, 0), (48_000, 72, 0.002), (44_100, 22, 0), (44_100, 23, 0.001),
    ])
    func roundsToMilliseconds(rate: Int, frames: Int, seconds: Double) throws {
        let session = try Self.session(rate: rate, [("c", Frames(frames), .chapter)])
        #expect(try Self.startTimes(session.chaptersJSON(in: 0..<Frames(rate), imageStem: "")) == [seconds])
    }

    /// C4, C3 of run 2026-10-11-chapters-in-file: "b" starts at the millisecond of "a", so the
    /// file drops it.
    @Test func orderIsPositionThenID() throws {
        let session = try Self.session([
            ("b", 96_000, .chapter), ("a", 96_000, .chapter), ("earlier", 48_000, .chapter),
        ])
        let titles = try Self.chapters(session.chaptersJSON(in: 0..<480_000, imageStem: "")).map {
            $0["title"] as? String
        }
        #expect(titles == ["earlier", "a"], "titles \(titles)")
    }

    /// C5f. "C" starts at the millisecond of "B", so the list drops it. A file with two chapters at
    /// one start stops the M4A writer (probe P1).
    @Test func aSecondChapterAtOneStartIsDropped() throws {
        var session = Session(sampleRate: 44_100)
        try session.setMarker(Marker(id: "a", name: "A", position: 0, kind: .chapter))
        try session.setMarker(Marker(id: "b", name: "B", position: 66_150, kind: .chapter))
        try session.setMarker(Marker(id: "c", name: "C", position: 66_150, kind: .chapter))
        let list = session.chapterList(in: 0..<132_300)
        #expect(list.chapters.map(\.name) == ["A", "B"], "kept \(list.chapters.map(\.name))")
        #expect(list.dropped.map(\.id) == ["c"], "dropped \(list.dropped.map(\.id))")
        let close = try Self.session(rate: 48_000, [("d", 23, .chapter), ("e", 24, .chapter), ("f", 0, .chapter)])
        #expect(close.chapterList(in: 0..<48_000).dropped.map(\.id) == ["d"], "23 frames round to 0 ms")
    }

    /// C5. The fields and types of JSON Chapters 1.2.0; the spec has no official JSON Schema (U11).
    /// Control: a `startTime` written as a string fails.
    @Test func fieldsAndTypesFollowSpec120() throws {
        let session = try Self.session([("one", 0, .chapter), ("two", 48_000, .chapter), ("three", 100_001, .chapter)])
        let data = try session.chaptersJSON(in: 0..<480_000, imageStem: "")
        let file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(file.keys) == ["version", "chapters"])
        #expect(file["version"] as? String == "1.2.0")
        let chapters = try #require(file["chapters"] as? [[String: Any]])
        let allowed: Set = ["startTime", "endTime", "title", "img", "url", "toc", "location"]
        var last = -1.0
        for chapter in chapters {
            #expect(Set(chapter.keys).isSubset(of: allowed))
            let start = try #require(chapter["startTime"] as? NSNumber)
            #expect(CFGetTypeID(start) != CFBooleanGetTypeID(), "startTime is a number, not a boolean")
            #expect(start.doubleValue >= 0 && start.doubleValue >= last, "startTime is 0 or more and does not go down")
            last = start.doubleValue
            #expect(chapter["title"] is String)
            if let toc = chapter["toc"] { #expect(CFGetTypeID(toc as CFTypeRef) == CFBooleanGetTypeID()) }
            if let end = chapter["endTime"] { #expect(end is NSNumber) }
        }
        #expect(chapters.count == 3)
    }

    /// C6. The callers check `chapters(in:)` before they make the JSON (code gate item 2).
    @Test func noChapterInRangeGivesNoChapter() throws {
        #expect(Session(sampleRate: 48_000).chapters(in: 0..<480_000).isEmpty, "no marker")
        #expect(try Self.session([("m", 48_000, .marker)]).chapters(in: 0..<480_000).isEmpty, "only a marker")
        let outside = try Self.session([("a", 47_999, .chapter), ("b", 96_000, .chapter)])
        #expect(outside.chapters(in: 48_000..<96_000).isEmpty, "only chapters outside the range")
    }

    /// C7.
    @Test func titleKeepsTheMarkerName() throws {
        let name = "Capítulo \"1\" / intro"
        var session = Session(sampleRate: 48_000)
        try session.setMarker(Marker(id: "c", name: name, position: 0, kind: .chapter))
        #expect(
            try Self.chapters(session.chaptersJSON(in: 0..<48_000, imageStem: "")).first?["title"] as? String == name)
    }

    /// C8. A ripple delete of 2 s on the speech track "a" only; the music on "s" is out of scope.
    /// The chapter at 10 s moves to 8 s (Rule M of decision 0037).
    @Test func chaptersFollowARippleWithTheMusicOutOfScope() throws {
        var session = try editFixture()
        try session.place(Clip(id: "speech", file: "f", start: 0, offset: 0, length: 480_000), on: "a")
        try session.place(Clip(id: "music", file: "g", start: 0, offset: 0, length: 480_000), on: "s")
        try session.setMarker(Marker(id: "c", name: "c", position: 480_000, kind: .chapter))
        try session.rippleDelete(96_000..<192_000, on: ["a"])
        #expect(session.markers["c"]?.position == 384_000)
        #expect(try Self.startTimes(session.chaptersJSON(in: 0..<session.end, imageStem: "")) == [8])
    }

    /// Run 2026-10-11-chapters-in-file, C3: "url" and "img" only for a chapter that has them. The
    /// image name is `<stem>-<n>.<ext>`, with n the place of the chapter in the file. A session with
    /// no URL and no image gives the bytes of today.
    @Test func aChapterWithAURLAndAnImageGetsUrlAndImg() throws {
        var session = Session(sampleRate: 48_000)
        try session.setMarker(Marker(id: "a", name: "A", position: 0, kind: .chapter))
        let today =
            "{\n  \"chapters\" : [\n    {\n      \"startTime\" : 0,\n      \"title\" : \"A\"\n    }\n  ],\n  \"version\" : \"1.2.0\"\n}"
        #expect(String(decoding: try session.chaptersJSON(in: 0..<480_000, imageStem: "show"), as: UTF8.self) == today)
        let png = try ArtworkName("0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.png")
        let jpeg = try ArtworkName("1B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.jpg")
        try session.setMarker(
            Marker(
                id: "b", name: "B", position: 48_000, kind: .chapter, url: try WebURL("https://example.com/b"),
                image: png))
        try session.setMarker(Marker(id: "c", name: "C", position: 96_000, kind: .chapter, image: jpeg))
        let chapters = try Self.chapters(session.chaptersJSON(in: 0..<480_000, imageStem: "show"))
        #expect(chapters[0]["url"] == nil && chapters[0]["img"] == nil, "A has neither key")
        #expect(
            chapters[1]["url"] as? String == "https://example.com/b" && chapters[1]["img"] as? String == "show-2.png")
        #expect(chapters[2]["url"] == nil && chapters[2]["img"] as? String == "show-3.jpg")
        let images = session.chapterImages(in: 0..<480_000, imageStem: "show")
        #expect(images.map(\.image) == [png, jpeg] && images.map(\.name) == ["show-2.png", "show-3.jpg"])
    }

    /// C18 of run 2026-10-17-agent-pack. Each line is `HH:MM:SS title`, the time from the range
    /// start rounded down to the second. Fail value: `59:59 End`, the `MM:SS` form.
    @Test func aTextChapterListUsesHoursInEveryLine() throws {
        let hour = try Self.session([("Intro", 0, .chapter), ("End", 172_800_000, .chapter)])
        #expect(hour.chaptersText(in: 0..<Frames.limit) == "00:00:00 Intro\n01:00:00 End\n")
        let under = try Self.session([("Intro", 0, .chapter), ("End", 172_752_000, .chapter)])
        #expect(under.chaptersText(in: 0..<Frames.limit) == "00:00:00 Intro\n00:59:59 End\n")
        // 3599 s and 47,999 frames are still second 3599.
        let n: Frames = 480_000
        let down = try Self.session([
            ("Intro", n, .chapter), ("End", n + 172_799_999, .chapter), ("Before", n - 1, .chapter),
            ("plain", n + 48_000, .marker),
        ])
        #expect(down.chaptersText(in: n..<Frames.limit) == "00:00:00 Intro\n00:59:59 End\n", "rounded down")
        // The session refuses tab, LF, and CR in a name; these line breaks it keeps.
        var titled = Session(sampleRate: 48_000)
        try titled.setMarker(Marker(id: "a", name: "Part\u{2028}One\u{85}A\u{2029}B", position: 0, kind: .chapter))
        #expect(titled.chaptersText(in: 0..<48_000) == "00:00:00 Part One A B\n")
    }
}
