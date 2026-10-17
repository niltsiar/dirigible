import Foundation
import Testing

@testable import DirigibleCore

/// `Session.heal` (C26 to C29 of run 2026-10-17-agent-pack). Tracks "t" and "u" (mono); files "f"
/// and "g" of 200 000 frames.
struct HealTests {
    var session: Session

    init() throws {
        session = Session(sampleRate: 48_000)
        for id in ["f", "g"] as [FileID] {
            try session.addFile(AudioFile(id: id, path: "\(id).wav", layout: .mono, length: 200_000))
        }
        try session.addTrack("t", name: "T", layout: .mono)
        try session.addTrack("u", name: "U", layout: .mono)
    }

    func lane(_ track: TrackID) -> [Clip] { session.track(track).map { Array($0.clips) } ?? [] }

    /// `count` pieces of 30 000 frames of file "f" on `track`: the first keeps `id`, the others are
    /// "<id>@30000" and so on.
    mutating func pieces(on track: TrackID, id: ClipID, count: Int) throws {
        try session.place(Clip(id: id, file: "f", start: 0, offset: 0, length: Frames(30_000 * count)), on: track)
        try session.splitClips(at: (1..<count).map { Frames(30_000 * $0) }, on: [track])
    }

    /// C26: a split at three points, then a heal of the session, gives the clip before the split,
    /// with its gain and both fades.
    @Test mutating func aHealUndoesASplit() throws {
        let whole = Clip(
            id: "A", file: "f", start: 1_000, offset: 500, length: 90_000, gain: Gain(dB: -3)!,
            fades: Fades(fadeIn: 480, fadeOut: 960)!)
        try session.place(whole, on: "t")
        let before = session
        try session.splitClips(at: [20_000, 50_000, 80_000], on: ["t"])
        #expect(lane("t").count == 4)

        #expect(try session.heal() == ["A"])

        #expect(session == before)
    }

    /// C26: the healed clip keeps the ID, the start, the offset, the gain, the start crossfade of the
    /// left piece, and the end crossfade of the right piece. The crossfade halves of the neighbors stay.
    @Test mutating func aHealKeepsTheOuterEdges() throws {
        let gain = Gain(dB: -3)!
        try session.place(Clip(id: "X", file: "g", start: 0, offset: 0, length: 10_000), on: "t")
        try session.place(Clip(id: "A", file: "f", start: 10_000, offset: 5_000, length: 10_000, gain: gain), on: "t")
        try session.place(Clip(id: "B", file: "f", start: 20_000, offset: 15_000, length: 10_000, gain: gain), on: "t")
        try session.place(Clip(id: "Y", file: "g", start: 30_000, offset: 50_000, length: 10_000), on: "t")
        try session.setCrossfades(["X": 2_000, "B": 2_000])

        #expect(try session.heal() == ["A"])

        let healed = Clip(
            id: "A", file: "f", start: 10_000, offset: 5_000, length: 20_000, gain: gain,
            crossfades: Crossfades(start: 2_000, end: 2_000)!)
        #expect(lane("t").map(\.id) == ["X", "A", "Y"])
        #expect(lane("t")[1] == healed)
        #expect(lane("t")[0].crossfades == Crossfades(start: 0, end: 2_000))
        #expect(lane("t")[2].crossfades == Crossfades(start: 2_000, end: 0))
        let same = try session.reopened() == session
        #expect(same, "the healed session saves and reads back")
    }

    /// C28: each join that changes the sound stays. The first case is the control: it heals.
    @Test func aHealSkipsEachJoinThatChangesTheSound() throws {
        let cases: [(name: String, heals: Bool, change: (inout Clip, inout Clip) -> Void)] = [
            ("a join with no change", true, { _, _ in }),
            ("a butt join", false, { _, b in b.file = "g" }),
            ("a gap in the file", false, { _, b in b.offset = b.offset + 5 }),
            ("two gains", false, { _, b in b.gain = Gain(dB: -3)! }),
            ("a fade-out at the join", false, { a, _ in a.fades = Fades(fadeIn: 0, fadeOut: 100)! }),
            ("a fade-in at the join", false, { _, b in b.fades = Fades(fadeIn: 100, fadeOut: 0)! }),
            ("a gap on the timeline", false, { _, b in b.start = b.start + 10 }),
        ]
        for (name, heals, change) in cases {
            var session = session
            var a = Clip(id: "A", file: "f", start: 0, offset: 0, length: 10_000)
            var b = Clip(id: "B", file: "f", start: 10_000, offset: 10_000, length: 10_000)
            change(&a, &b)
            try session.place(a, on: "t")
            try session.place(b, on: "t")
            let before = session
            if heals {
                #expect(try session.heal() == ["A"], "\(name)")
                #expect(session.track("t").map { Array($0.clips).map(\.length) } == [20_000], "\(name)")
            } else {
                #expect(throws: SessionError.nothingToHeal, "\(name)") { try session.heal() }
                #expect(session == before, "\(name)")
            }
        }
    }

    /// C29: three pieces heal to one clip in one call. A join in `from...to` heals: a join at `to`
    /// does, and a join at `to + 1` does not. With `tracks`, only those tracks heal.
    @Test mutating func aHealJoinsEveryPieceInTheRange() throws {
        try pieces(on: "t", id: "P", count: 4)
        try pieces(on: "u", id: "Q", count: 2)
        let before = session

        #expect(try session.heal(tracks: ["u"]) == ["Q"])
        #expect(lane("u").map(\.length) == [60_000] && lane("t").count == 4)

        session = before
        #expect(try session.heal(tracks: ["t"], range: 30_000...60_000) == ["P"], "joins at 30 000 and 60 000")
        #expect(lane("t").map(\.length) == [90_000, 30_000])

        session = before
        #expect(try session.heal(tracks: ["t"], range: 30_001...90_000) == ["P@30000"], "joins at 60 000 and 90 000")
        #expect(lane("t").map(\.length) == [30_000, 90_000])

        session = before
        #expect(try session.heal(tracks: ["t"], range: 30_000...59_999) == ["P"], "the join at 60 000 stays")
        #expect(lane("t").map(\.length) == [60_000, 30_000, 30_000])

        session = before
        #expect(try session.heal() == ["P", "Q"], "all tracks, in track order")
        #expect(lane("t").map(\.length) == [120_000] && lane("u").map(\.length) == [60_000])

        session = before
        #expect(throws: SessionError.unknownTrack("x")) { try session.heal(tracks: ["u", "x"]) }
        #expect(throws: SessionError.nothingToHeal) { try session.heal(range: 1...29_999) }
        #expect(session == before, "a throw changes nothing")
    }

    /// C29: the words keep their text and number. A word that crossed the join shows its whole
    /// range under the healed clip, and an occurrence from before the heal that names the right
    /// piece is refused.
    @Test func aHealKeepsTheTranscriptWords() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 100_000), on: "host")
        session.addWords(
            [(1, 10_000..<20_000, "one"), (2, 45_000..<55_000, "two"), (3, 80_000..<90_000, "three")], file: "h")
        try session.split("H", at: 50_000)
        let before = session.words()
        #expect(before.map(\.occurrence.clip) == ["H", "H@50000", "H@50000"])
        #expect(before.map(\.range)[1] == 50_000..<55_000, "clamped to the right piece")

        #expect(try session.heal() == ["H"])

        let after = session.words()
        #expect(
            after.map(\.text) == before.map(\.text) && after.map(\.occurrence.word) == before.map(\.occurrence.word))
        #expect(after.map(\.occurrence.clip) == ["H", "H", "H"])
        #expect(after.map(\.range) == [10_000..<20_000, 45_000..<55_000, 80_000..<90_000])
        let stale = before[1].occurrence
        #expect(throws: SessionError.unknownWord(stale)) { try session.cutWords([stale]) }
    }
}
