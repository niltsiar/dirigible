import Foundation
import Testing

@testable import DirigibleCore

/// The Podcasting 2.0 JSON Chapters 1.2.0 file of the chapter markers in a range (run
/// 2026-10-09-chapters-export, criteria C1 to C8).
struct ChaptersTests {
    /// The chapters of the JSON as plain objects, through `JSONSerialization`.
    static func chapters(_ data: Data?) throws -> [[String: Any]] {
        let data = try #require(data, "the range has a chapter")
        let file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(file["chapters"] as? [[String: Any]])
    }

    static func startTimes(_ data: Data?) throws -> [Double] {
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
        #expect(try Self.startTimes(session.chaptersJSON(in: n..<1_440_000)) == [0, 2, 19.999])
    }

    /// C3. Half up at the millisecond: 24 frames at 48 kHz are 0.5 ms.
    @Test(arguments: [
        (48_000, 24, 0.001), (48_000, 23, 0), (48_000, 72, 0.002), (44_100, 22, 0), (44_100, 23, 0.001),
    ])
    func roundsToMilliseconds(rate: Int, frames: Int, seconds: Double) throws {
        let session = try Self.session(rate: rate, [("c", Frames(frames), .chapter)])
        #expect(try Self.startTimes(session.chaptersJSON(in: 0..<Frames(rate))) == [seconds])
    }

    /// C4.
    @Test func orderIsPositionThenID() throws {
        let session = try Self.session([
            ("b", 96_000, .chapter), ("a", 96_000, .chapter), ("earlier", 48_000, .chapter),
        ])
        let titles = try Self.chapters(session.chaptersJSON(in: 0..<480_000)).map { $0["title"] as? String }
        #expect(titles == ["earlier", "a", "b"])
    }

    /// C5. The fields and types of JSON Chapters 1.2.0; the spec has no official JSON Schema (U11).
    /// Control: a `startTime` written as a string fails.
    @Test func fieldsAndTypesFollowSpec120() throws {
        let session = try Self.session([("one", 0, .chapter), ("two", 48_000, .chapter), ("three", 100_001, .chapter)])
        let data = try #require(session.chaptersJSON(in: 0..<480_000))
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

    /// C6.
    @Test func noChapterInRangeGivesNil() throws {
        #expect(Session(sampleRate: 48_000).chaptersJSON(in: 0..<480_000) == nil, "no marker")
        #expect(try Self.session([("m", 48_000, .marker)]).chaptersJSON(in: 0..<480_000) == nil, "only a marker")
        let outside = try Self.session([("a", 47_999, .chapter), ("b", 96_000, .chapter)])
        #expect(outside.chaptersJSON(in: 48_000..<96_000) == nil, "only chapters outside the range")
    }

    /// C7.
    @Test func titleKeepsTheMarkerName() throws {
        let name = "Capítulo \"1\" / intro"
        var session = Session(sampleRate: 48_000)
        try session.setMarker(Marker(id: "c", name: name, position: 0, kind: .chapter))
        #expect(try Self.chapters(session.chaptersJSON(in: 0..<48_000)).first?["title"] as? String == name)
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
        #expect(try Self.startTimes(session.chaptersJSON(in: 0..<session.end)) == [8])
    }
}
