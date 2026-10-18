import Foundation
import Testing

@testable import DirigibleCore

/// `Session.heal`. Tracks "t" and "u" (mono); files "f"
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

    /// A split at three points, then a heal of the session, gives the clip before the split,
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

    /// The healed clip keeps the ID, the start, the offset, the gain, the start crossfade of the
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

    /// Each join that changes the sound stays. The first case is the control: it heals.
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

    /// C3: a heal needs equal envelope gain at each file frame of the joined range (0 ..< 20 000).
    /// Two parts of one split heal to the list of the clip. A right list that differs only after the
    /// range heals to the points of A before the join and of B from it. A step at the join and an
    /// equal value at the join with another slope do not heal.
    @Test func aJoinWithDifferentEnvelopeGainsDoesNotHeal() throws {
        var split = session
        let whole = Clip(
            id: "A", file: "f", start: 0, offset: 0, length: 20_000, envelope: envelope([(5_000, -6), (15_000, 0)]))
        try split.place(whole, on: "t")
        let before = split
        try split.split("A", at: 10_000)
        #expect(try split.heal() == ["A"], "two parts of one split")
        #expect(split == before)

        let cases: [(name: String, a: GainEnvelope, b: GainEnvelope, healed: GainEnvelope?)] = [
            (
                "the right list differs only after the range", envelope([(0, -3), (25_000, -3)]),
                envelope([(0, -3), (25_000, -3), (40_000, -12)]), envelope([(0, -3), (25_000, -3), (40_000, -12)])
            ),
            ("a step of 1 dB at the join", .empty, envelope([(10_000, -1)]), nil),
            (
                "an equal value at the join with another slope", envelope([(0, 0), (20_000, -10)]),
                envelope([(0, -10), (20_000, 0)]), nil
            ),
        ]
        for (name, envelopeA, envelopeB, healed) in cases {
            var session = session
            try session.place(
                Clip(id: "A", file: "f", start: 0, offset: 0, length: 10_000, envelope: envelopeA), on: "t")
            try session.place(
                Clip(id: "B", file: "f", start: 10_000, offset: 10_000, length: 10_000, envelope: envelopeB), on: "t")
            let before = session
            if let healed {
                #expect(try session.heal() == ["A"], "\(name)")
                #expect(session.track("t").map { Array($0.clips).map(\.envelope) } == [healed], "\(name)")
            } else {
                #expect(throws: SessionError.nothingToHeal, "\(name)") { try session.heal() }
                #expect(session == before, "\(name)")
            }
        }
    }

    /// Three pieces heal to one clip in one call. A join in `from...to` heals: a join at `to`
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

    /// The words keep their text and number. A word that crossed the join shows its whole
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
