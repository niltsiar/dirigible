import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Criteria X1 to X4 of run 2026-10-28-session-index-zoom, on session `I`: tracks Host and Guest;
/// clips a, b, c; marker m1 and chapter h1 at 48,000; marker m2 at 240,000.
struct SessionIndexTests {
    static func session() throws -> Session {
        var session = Session(sampleRate: 48_000)
        for (id, path) in [("fa", "Capture/take1-1-1.wav"), ("fb", "Café intro.wav"), ("fc", "Capture/take2-1-1.wav")] {
            try session.addFile(AudioFile(id: FileID(id), path: path, layout: .mono, length: 480_000))
        }
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.place(Clip(id: "a", file: "fa", start: 0, offset: 0, length: 96_000), on: "t1")
        try session.place(Clip(id: "b", file: "fb", start: 48_000, offset: 0, length: 96_000), on: "t2")
        try session.place(Clip(id: "c", file: "fc", start: 192_000, offset: 0, length: 96_000), on: "t1")
        try session.setMarker(Marker(id: "m1", name: "Breath", position: 48_000, kind: .marker))
        try session.setMarker(Marker(id: "h1", name: "Intro", position: 48_000, kind: .chapter))
        try session.setMarker(Marker(id: "m2", name: "Cut here", position: 240_000, kind: .marker))
        return session
    }

    func ids(_ rows: [SessionIndex.Row]) -> [String] {
        rows.map {
            switch $0.item {
            case .clip(let id, _): id.rawValue
            case .marker(let id), .chapter(let id): id.rawValue
            }
        }
    }

    func index() throws -> SessionIndex { SessionIndex(session: try Self.session()) }

    @Test func theRowsFollowTheTimeline() throws {
        #expect(ids(try index().rows) == ["a", "h1", "m1", "b", "c", "m2"])
    }

    @Test func aTieBreaksByKindThenTrackOrder() throws {
        var session = try Self.session()
        try session.addTrack("t3", name: "Third", layout: .mono)
        try session.place(Clip(id: "0", file: "fa", start: 192_000, offset: 0, length: 96_000), on: "t3")
        try session.place(Clip(id: "d", file: "fa", start: 192_000, offset: 0, length: 96_000), on: "t2")
        try session.setMarker(Marker(id: "z", name: "Z", position: 192_000, kind: .marker))
        try session.setMarker(Marker(id: "y", name: "Y", position: 192_000, kind: .marker))
        let rows = SessionIndex(session: session).rows.filter { $0.position == 192_000 }
        #expect(ids(rows) == ["y", "z", "c", "d", "0"], "markers by ID, then clips by track order")
    }

    @Test func aRowShowsItsNameTrackAndTime() throws {
        let rows = try index().rows
        let b = try #require(rows.first { $0.item == .clip("b", track: "Guest") })
        #expect(b.name == "Café intro")
        #expect(b.position == 48_000)
        let a = try #require(rows.first { $0.item == .clip("a", track: "Host") })
        #expect(a.name == "Capture/take1-1-1", "the clip name, not the file ID")
        #expect(rows.first { $0.item == .chapter("h1") }?.name == "Intro")
        #expect(rows.first { $0.item == .marker("m2") }?.position == 240_000)
    }

    @Test func theFilterKeepsOneKind() throws {
        let index = try index()
        #expect(ids(index.rows(kind: nil, search: "")).count == 6)
        #expect(ids(index.rows(kind: .clip, search: "")) == ["a", "b", "c"])
        #expect(ids(index.rows(kind: .marker, search: "")) == ["m1", "m2"])
        #expect(ids(index.rows(kind: .chapter, search: "")) == ["h1"])
    }

    @Test func theSearchIgnoresCaseAndAccents() throws {
        let index = try index()
        func found(_ text: String, _ kind: SessionIndex.Kind? = nil) -> [String] {
            ids(index.rows(kind: kind, search: text))
        }
        #expect(found("cafe") == ["b"])
        #expect(found("CAFÉ") == ["b"])
        #expect(found("CAPTURE") == ["a", "c"])
        #expect(found("guest") == ["b"], "the track name")
        #expect(found("take2") == ["c"])
        #expect(found("zzz") == [])
        #expect(found("") == ["a", "h1", "m1", "b", "c", "m2"])
        #expect(found("c", .marker) == ["m2"], "the search and the filter combine")
        #expect(found("cut here") == ["m2"], "a space is part of the text")
        #expect(found("Host") == ["a", "c"], "a marker has no track name")
    }

    @Test func aMarkerRowDoesNotMatchTheTextOfAClipTrack() throws {
        #expect(ids(try index().rows(kind: .marker, search: "host")) == [])
    }
}
