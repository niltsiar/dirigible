import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// The rows of the session index, on a session with tracks Host and Guest;
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

    func row(_ id: String, in session: Session) throws -> SessionIndex.Row {
        try #require(SessionIndex(session: session).rows.first { ids([$0]) == [id] })
    }

    /// The session ends at 288,000, the end of clip c.
    @Test func aChapterLastsToTheNextChapter() throws {
        var session = try Self.session()
        #expect(try row("h1", in: session).duration == 240_000, "5 s to the session end, not 4 s to the marker m2")
        #expect(try row("m1", in: session).duration == nil, "a marker has no duration")
        #expect(try row("m2", in: session).duration == nil)
        #expect(try row("a", in: session).duration == 96_000, "a clip lasts its length")
        #expect(try row("b", in: session).duration == 96_000)
        try session.setMarker(Marker(id: "h2", name: "Next", position: 144_000, kind: .chapter))
        #expect(try row("h1", in: session).duration == 96_000, "2 s to the next chapter")
        #expect(try row("h2", in: session).duration == 144_000, "to the session end")
        try session.setMarker(Marker(id: "h3", name: "Late", position: 400_000, kind: .chapter))
        #expect(try row("h3", in: session).duration == .zero, "a chapter after the session end lasts 0")
        #expect(try row("h2", in: session).duration == 256_000, "to the chapter h3")
    }

    /// A ripple runs the pass at each edit of a list of 12,250 rows with 50 chapters: it reads the
    /// chapter rows only. It returns the count of rows that it read.
    @Test func theDurationPassReadsOnlyTheChapterRows() throws {
        var session = try Self.session()
        for (n, position) in [100_000, 144_000, 400_000].enumerated() {
            let chapter = Marker(id: MarkerID("k\(n)"), name: "Chapter", position: Frames(position), kind: .chapter)
            try session.setMarker(chapter)
        }
        var rows = SessionIndex(session: session).rows
        let before = rows
        #expect(rows.count == 9)
        #expect(SessionIndex.setChapterDurations(&rows, in: session) == 4, "h1, k0, k1, and k2")
        #expect(rows == before, "the pass gives the same durations")
        #expect(try row("k1", in: session).duration == 256_000, "to the chapter k2 past the end")
        #expect(try row("k2", in: session).duration == .zero, "a chapter after the session end lasts 0")
    }

    @Test func anEndTrimChangesTheDurationsInAnUpdate() throws {
        let before = try Self.session()
        var after = before
        try after.trim("c", to: 192_000..<240_000)
        let updated = SessionIndex(session: after, updating: SessionIndex(session: before), of: before)
        #expect(updated == SessionIndex(session: after))
        #expect(try row("c", in: after).duration == 48_000, "the clip lasts its new length")
        #expect(updated.rows.first { ids([$0]) == ["c"] }?.duration == 48_000)
        #expect(updated.rows.first { ids([$0]) == ["h1"] }?.duration == 192_000, "the session end moved to 240,000")
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

    @Test func theShownPicksFollowTheKindAndTheSearch() throws {
        let index = try index()
        let all: Set<SessionIndex.Pick> = [
            .clip("a"), .clip("b"), .clip("c"), .marker("h1"), .marker("m1"), .marker("m2"),
        ]
        func shown(
            _ picks: Set<SessionIndex.Pick>, _ kind: SessionIndex.Kind?, _ search: String,
            keeping: SessionIndex.Pick? = nil
        ) -> Set<SessionIndex.Pick> {
            index.shownPicks(of: picks, kind: kind, search: search, keeping: keeping)
        }
        #expect(shown(all, nil, "capture") == [.clip("a"), .clip("c")])
        #expect(shown(all, .marker, "") == [.marker("m1"), .marker("m2")], "a chapter is not a marker")
        #expect(shown(all, nil, "capture", keeping: .marker("m1")) == [.clip("a"), .clip("c"), .marker("m1")])
        #expect(shown([.clip("b"), .marker("m1")], nil, "capture") == [], "a pick that no row shows goes")
        #expect(shown([.clip("b"), .marker("m1")], nil, "") == [.clip("b"), .marker("m1")])
        #expect(shown(all, .chapter, "x") == [], "the filter and the search combine")
        #expect(shown([], .marker, "zzz") == [])
        #expect(shown([.clip("gone")], nil, "capture") == [.clip("gone")], "a gone pick is not a hidden row")
    }

    @Test func aMarkerRowDoesNotMatchTheTextOfAClipTrack() throws {
        #expect(ids(try index().rows(kind: .marker, search: "host")) == [])
    }

    @Test func anUpdateAfterADeleteGivesTheRowsOfAFullBuild() throws {
        let before = try Self.session()
        var after = before
        try after.removeClips(["c"])
        let updated = SessionIndex(session: after, updating: SessionIndex(session: before), of: before)
        #expect(ids(updated.rows) == ["a", "h1", "m1", "b", "m2"])
    }

    /// 400 seeded edits through the public edits of `Session`, each index updated from the one
    /// before: clips removed, placed, moved, and trimmed, files added, a gain, markers set and
    /// removed, and tracks renamed. Each update equals a full build.
    @Test func eachUpdateGivesTheRowsOfAFullBuild() throws {
        var random = SplitMix(seed: 0x1D3)
        var session = try Self.session()
        try session.addTrack("t3", name: "Third", layout: .mono)
        let tracks: [TrackID] = ["t1", "t2", "t3"]
        for n in 0..<60 {
            let start = Frames(300_000 + n * 50_000)
            try session.place(
                Clip(id: ClipID("k\(n)"), file: "fa", start: start, offset: 0, length: 40_000), on: tracks[n % 3])
        }
        var index = SessionIndex(session: session)
        var mismatches: [Int] = []
        for step in 0..<400 {
            let before = session
            let clips = session.tracks.flatMap(\.clips)
            let markers = Array(session.markers.values)
            let at = Frames(Int.random(in: 0..<80, using: &random) * 25_000)
            let track = tracks.randomElement(using: &random)!
            switch Int.random(in: 0..<10, using: &random) {
            case 0 where !clips.isEmpty:
                try session.removeClips([clips.randomElement(using: &random)!.id])
            case 1:
                try? session.place(
                    Clip(id: ClipID("n\(step)"), file: "fb", start: at, offset: 0, length: 20_000), on: track)
            case 2 where !clips.isEmpty:
                try? session.move(clips.randomElement(using: &random)!.id, to: track, start: at)
            case 3 where !clips.isEmpty:
                let clip = clips.randomElement(using: &random)!
                try? session.trim(clip.id, to: clip.start + 1_000..<clip.end)
            case 4:
                let file = FileID("f\(step)")
                try session.addFile(AudioFile(id: file, path: "File \(step).wav", layout: .mono, length: 480_000))
                try? session.place(
                    Clip(id: ClipID("f\(step)"), file: file, start: at, offset: 0, length: 20_000), on: track)
            case 5 where !clips.isEmpty:
                try session.setGain(Gain(dB: -3)!, clip: clips.randomElement(using: &random)!.id)
            case 6:
                let old = markers.randomElement(using: &random)?.id
                let id = Bool.random(using: &random) ? old ?? MarkerID("x\(step)") : MarkerID("x\(step)")
                let kind: Marker.Kind = Bool.random(using: &random) ? .marker : .chapter
                try? session.setMarker(Marker(id: id, name: "Mark \(step)", position: at, kind: kind))
            case 7 where !markers.isEmpty:
                try session.removeMarker(markers.randomElement(using: &random)!.id)
            case 8:
                try session.renameTrack(track, to: "Track \(step)")
            case 9 where !clips.isEmpty:
                let clip = clips.randomElement(using: &random)!
                try? session.trim(clip.id, to: clip.start..<clip.end - 1_000)
            default: break
            }
            index = SessionIndex(session: session, updating: index, of: before)
            if index != SessionIndex(session: session) { mismatches.append(step) }
        }
        let equal = mismatches.isEmpty
        #expect(equal, "the steps whose update differs from a full build: \(mismatches.prefix(10))")
    }

    /// 300 seeded ripple edits, each index updated from the one before: Delete and Close Gap and
    /// Insert Silence on all tracks or on some, Close Gaps, a ripple paste, and Undo and Redo of
    /// them. Each ripple moves the later rows, so a wrong shift of one row gives a wrong order or
    /// start. Each update equals a full build.
    @Test func eachRippleUpdateGivesTheRowsOfAFullBuild() throws {
        var random = SplitMix(seed: 0x51F7)
        var session = try Self.session()
        try session.addTrack("t3", name: "Third", layout: .mono)
        let tracks: [TrackID] = ["t1", "t2", "t3"]
        for n in 0..<90 {
            try session.place(
                Clip(id: ClipID("k\(n)"), file: "fa", start: Frames(300_000 + n * 30_000), offset: 0, length: 20_000),
                on: tracks[n % 3])
        }
        for n in 0..<20 {
            try session.setMarker(
                Marker(
                    id: MarkerID("r\(n)"), name: "Mark \(n)", position: Frames(n * 150_000),
                    kind: n % 4 == 0 ? .chapter : .marker))
        }
        var (undo, redo): ([Session], [Session]) = ([], [])
        var index = SessionIndex(session: session)
        var mismatches: [Int] = []
        for step in 0..<300 {
            let before = session
            let at = Frames(Int.random(in: 0..<120, using: &random) * 25_000)
            let length = Frames(Int.random(in: 1..<8, using: &random) * 10_000)
            let some = tracks.filter { _ in Bool.random(using: &random) }
            let scope = Bool.random(using: &random) || some.isEmpty ? tracks : some
            let edit = Int.random(in: 0..<6, using: &random)
            switch edit {
            case 0: try? session.rippleDelete(at..<at + length, on: scope, naming: scope)
            case 1: try? session.rippleInsert(length, at: at, on: scope, naming: scope)
            case 2:
                let clips = session.tracks.flatMap(\.clips).filter { _ in Int.random(in: 0..<4, using: &random) == 0 }
                _ = try? session.closeGaps(clips.map(\.id))
            case 3:
                if let excerpt = try? session.excerpt(of: at..<at + length, on: scope) {
                    let place = Frames(Int.random(in: 0..<120, using: &random) * 25_000)
                    try? session.rippleInsert(excerpt.length, at: place, on: tracks, naming: tracks)
                    _ = try? session.paste(excerpt, at: place, on: scope)
                }
            case 4:
                guard let last = undo.popLast() else { break }
                redo.append(session)
                session = last
            default:
                guard let next = redo.popLast() else { break }
                undo.append(session)
                session = next
            }
            if edit < 4, session != before {
                undo.append(before)
                redo.removeAll()
            }
            index = SessionIndex(session: session, updating: index, of: before)
            if index != SessionIndex(session: session) { mismatches.append(step) }
        }
        let equal = mismatches.isEmpty
        #expect(equal, "the steps whose update differs from a full build: \(mismatches.prefix(10))")
    }

    /// Clips and marks on a grid of 10 places over 3 tracks, so many rows tie on the position; 300
    /// seeded sets of picks, some of them gone from the session.
    @Test func theFirstPickInTimelineOrderMatchesAFullBuild() throws {
        var random = SplitMix(seed: 0xF1257)
        var session = try Self.session()
        try session.addTrack("t3", name: "Third", layout: .mono)
        let tracks: [TrackID] = ["t1", "t2", "t3"]
        for n in 0..<40 {
            try? session.place(
                Clip(id: ClipID("k\(n)"), file: "fa", start: Frames(n % 10 * 10_000), offset: 0, length: 5_000),
                on: tracks[n % 3])
            let kind: Marker.Kind = n % 2 == 0 ? .marker : .chapter
            try session.setMarker(
                Marker(id: MarkerID("x\(n)"), name: "M", position: Frames(n % 10 * 10_000), kind: kind))
        }
        let order = SessionIndex(session: session).rows.map(\.id)
        let gone: [SessionIndex.Pick] = [.clip("gone"), .marker("gone")]
        var mismatches: [Set<SessionIndex.Pick>] = []
        for _ in 0..<300 {
            let picks = Set((order + gone).filter { _ in Int.random(in: 0..<8, using: &random) == 0 })
            if SessionIndex.first(of: picks, in: session) != order.first(where: picks.contains) {
                mismatches.append(picks)
            }
        }
        #expect(SessionIndex.first(of: Set(gone), in: session) == nil, "no pick in the session gives nil")
        #expect(mismatches.isEmpty, "\(mismatches.count) sets whose first pick differs, one: \(mismatches.first ?? [])")
    }
}

/// SplitMix64, so each seed gives the same edits on each run.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
