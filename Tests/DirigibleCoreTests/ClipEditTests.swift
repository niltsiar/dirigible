import DirigibleCore
import Foundation
import Testing

/// Clip edits with literal frames. A file "f1" of 100 000 frames, a mono track "t1".
struct ClipEditTests {
    var session: Session

    init() throws {
        session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "a.wav", layout: .mono, length: 100_000))
        try session.addFile(AudioFile(id: "s1", path: "s.wav", layout: .stereo, length: 100_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
    }

    func clip(_ id: ClipID, start: Frames, offset: Frames = 0, length: Frames) -> Clip {
        Clip(id: id, file: "f1", start: start, offset: offset, length: length)
    }

    func lane(_ track: TrackID) -> [Clip] {
        session.track(track).map { Array($0.clips) } ?? []
    }

    @Test mutating func placeOnAnEmptyTrack() throws {
        try session.place(clip("c1", start: 1_000, length: 50_000), on: "t1")
        #expect(lane("t1") == [clip("c1", start: 1_000, length: 50_000)])
        #expect(session.clip("c1")?.track == "t1")
    }

    @Test mutating func placeKeepsTheClipsSortedByStart() throws {
        try session.place(clip("c2", start: 60_000, length: 10_000), on: "t1")
        try session.place(clip("c1", start: 0, length: 10_000), on: "t1")
        #expect(lane("t1").map(\.id) == ["c1", "c2"])
    }

    @Test mutating func placeOverTheMiddleOfAClipSplitsIt() throws {
        try session.place(clip("c1", start: 0, length: 90_000), on: "t1")
        try session.place(clip("c2", start: 30_000, offset: 0, length: 20_000), on: "t1")
        #expect(
            lane("t1") == [
                clip("c1", start: 0, length: 30_000),
                clip("c2", start: 30_000, length: 20_000),
                clip("c1@50000", start: 50_000, offset: 50_000, length: 40_000),
            ])
    }

    @Test mutating func placeOverTheEdgesTrimsTheClipsUnder() throws {
        try session.place(clip("a", start: 0, length: 40_000), on: "t1")
        try session.place(clip("b", start: 50_000, length: 40_000), on: "t1")
        try session.place(clip("c", start: 30_000, offset: 0, length: 30_000), on: "t1")
        #expect(
            lane("t1") == [
                clip("a", start: 0, length: 30_000),
                clip("c", start: 30_000, length: 30_000),
                clip("b", start: 60_000, offset: 10_000, length: 30_000),
            ])
    }

    @Test mutating func placeOverAWholeClipRemovesIt() throws {
        try session.place(clip("a", start: 10_000, length: 10_000), on: "t1")
        try session.place(clip("b", start: 0, length: 50_000), on: "t1")
        #expect(lane("t1") == [clip("b", start: 0, length: 50_000)])
    }

    @Test mutating func placeOfAnEqualClipChangesNothing() throws {
        try session.place(clip("c1", start: 0, length: 10_000), on: "t1")
        let before = session
        try session.place(clip("c1", start: 0, length: 10_000), on: "t1")
        #expect(session == before)
        #expect(throws: SessionError.duplicateID("c1")) {
            try session.place(clip("c1", start: 20_000, length: 10_000), on: "t2")
        }
    }

    @Test mutating func placeRefusesAClipThatDoesNotFit() throws {
        let before = session
        #expect(throws: SessionError.clipOutsideFile("c1")) {
            try session.place(clip("c1", start: 0, offset: 60_000, length: 50_000), on: "t1")
        }
        #expect(throws: SessionError.clipOutsideFile("c1")) {
            try session.place(clip("c1", start: 0, length: 0), on: "t1")
        }
        #expect(throws: SessionError.clipOutsideFile("c1")) {
            try session.place(clip("c1", start: 0, offset: Frames(.max - 10), length: Frames(.max - 10)), on: "t1")
        }
        #expect(throws: SessionError.frameOutOfRange) {
            try session.place(clip("c1", start: -1, length: 10), on: "t1")
        }
        #expect(throws: SessionError.frameOutOfRange) {
            try session.place(clip("c1", start: Frames(.max - 5), length: 10), on: "t1")
        }
        #expect(throws: SessionError.frameOutOfRange) {
            try session.place(clip("c1", start: 0, offset: -1, length: 10), on: "t1")
        }
        #expect(throws: SessionError.unknownFile("f9")) {
            try session.place(Clip(id: "c1", file: "f9", start: 0, offset: 0, length: 10), on: "t1")
        }
        #expect(throws: SessionError.layoutMismatch("t1", .file("s1"))) {
            try session.place(Clip(id: "c1", file: "s1", start: 0, offset: 0, length: 10), on: "t1")
        }
        #expect(session == before)
    }

    @Test mutating func clearLeavesAGap() throws {
        try session.place(clip("c1", start: 0, length: 90_000), on: "t1")
        try session.clear(30_000..<50_000, on: "t1")
        #expect(
            lane("t1") == [
                clip("c1", start: 0, length: 30_000),
                clip("c1@50000", start: 50_000, offset: 50_000, length: 40_000),
            ])
    }

    @Test mutating func splitReturnsTheRightHalf() throws {
        try session.place(clip("c1", start: 10_000, offset: 5_000, length: 50_000), on: "t1")
        let right = try session.split("c1", at: 30_000)
        #expect(right == "c1@30000")
        #expect(
            lane("t1") == [
                clip("c1", start: 10_000, offset: 5_000, length: 20_000),
                clip("c1@30000", start: 30_000, offset: 25_000, length: 30_000),
            ])
        #expect(throws: SessionError.frameOutsideClip("c1", 10_000)) { try session.split("c1", at: 10_000) }
        #expect(throws: SessionError.frameOutsideClip("c1", 30_000)) { try session.split("c1", at: 30_000) }
        #expect(throws: SessionError.unknownClip("c9")) { try session.split("c9", at: 1) }
    }

    @Test mutating func splitTakesTheFirstFreeDerivedID() throws {
        try session.place(clip("c1", start: 0, length: 60_000), on: "t1")
        try session.split("c1", at: 30_000)
        try session.move("c1@30000", to: "t2", start: 0)
        try session.trim("c1", to: 0..<60_000)
        #expect(try session.split("c1", at: 30_000) == "c1@30000-2")
        #expect(throws: SessionError.duplicateID("c1@30000")) {
            try session.split("c1", at: 10_000, rightID: "c1@30000")
        }
    }

    @Test mutating func placeTakesTheFirstFreeDerivedID() throws {
        try session.place(clip("c1", start: 0, length: 60_000), on: "t1")
        try session.place(clip("p1", start: 20_000, length: 10_000), on: "t1")
        try session.move("c1@30000", to: "t2", start: 0)
        try session.clear(20_000..<30_000, on: "t1")
        try session.trim("c1", to: 0..<60_000)
        try session.place(clip("p2", start: 20_000, length: 10_000), on: "t1")
        #expect(lane("t1").map(\.id) == ["c1", "p2", "c1@30000-2"])
    }

    @Test mutating func aSplitNeverTakesTheIDOfThePlacedClip() throws {
        try session.place(clip("a", start: 0, length: 3_000), on: "t1")
        try session.place(clip("a@100", start: 100, length: 50), on: "t1")
        #expect(lane("t1").map(\.id) == ["a", "a@100", "a@150"])

        try session.place(clip("b", start: 10_000, length: 3_000), on: "t2")
        try session.split("b", at: 11_000)
        try session.move("b@11000", to: "t1", start: 20_000)
        try session.trim("b", to: 10_000..<13_000)
        try session.trim("b@11000", to: 20_000..<20_500)
        try session.move("b@11000", to: "t2", start: 10_500)
        #expect(lane("t2").map(\.id) == ["b", "b@11000", "b@11000-2"])
    }

    @Test mutating func moveBeyondTheFrameLimitChangesNothing() throws {
        try session.place(clip("c1", start: 0, length: 10_000), on: "t1")
        let before = session
        #expect(throws: SessionError.frameOutOfRange) { try session.move("c1", to: "t2", start: Frames.limit + 1) }
        #expect(session == before)
    }

    @Test mutating func moveToAnotherTrackOverwritesThere() throws {
        try session.place(clip("c1", start: 0, length: 10_000), on: "t1")
        try session.place(clip("c2", start: 0, length: 30_000), on: "t2")
        try session.move("c1", to: "t2", start: 10_000)
        #expect(lane("t1").isEmpty)
        #expect(
            lane("t2") == [
                clip("c2", start: 0, length: 10_000),
                clip("c1", start: 10_000, length: 10_000),
                clip("c2@20000", start: 20_000, offset: 20_000, length: 10_000),
            ])
    }

    @Test mutating func moveOnTheSameTrackCanOverlapItsOldPlace() throws {
        try session.place(clip("c1", start: 0, length: 10_000), on: "t1")
        try session.move("c1", to: "t1", start: 5_000)
        #expect(lane("t1") == [clip("c1", start: 5_000, length: 10_000)])
    }

    @Test mutating func trimMovesTheEdgesInsideTheFile() throws {
        try session.place(clip("c1", start: 10_000, offset: 5_000, length: 20_000), on: "t1")
        try session.trim("c1", to: 5_000..<40_000)
        #expect(lane("t1") == [clip("c1", start: 5_000, offset: 0, length: 35_000)])
        #expect(throws: SessionError.clipOutsideFile("c1")) { try session.trim("c1", to: 4_999..<40_000) }
        #expect(throws: SessionError.clipOutsideFile("c1")) { try session.trim("c1", to: 5_000..<105_001) }
        #expect(throws: SessionError.clipOutsideFile("c1")) { try session.trim("c1", to: 5_000..<5_000) }
    }

    @Test mutating func trimRefusesToGrowIntoANeighbor() throws {
        try session.place(clip("a", start: 0, length: 10_000), on: "t1")
        try session.place(clip("b", start: 20_000, offset: 20_000, length: 10_000), on: "t1")
        let before = session
        #expect(throws: SessionError.overlap("b", "a")) { try session.trim("b", to: 5_000..<30_000) }
        #expect(session == before)
    }

    @Test mutating func aTrackWithClipsKeepsItsLayout() throws {
        try session.place(clip("c1", start: 0, length: 10), on: "t1")
        #expect(throws: SessionError.layoutMismatch("t1", .trackHasClips)) {
            try session.setLayout(.stereo, route: nil, track: "t1")
        }
    }

    @Test mutating func aFileWithClipsStaysInThePool() throws {
        try session.place(clip("c1", start: 0, length: 10), on: "t1")
        #expect(throws: SessionError.fileInUse("f1")) { try session.removeFile("f1") }
    }

    @Test mutating func clipGainChanges() throws {
        try session.place(clip("c1", start: 0, length: 10), on: "t1")
        try session.setGain(Gain(dB: 4)!, clip: "c1")
        #expect(lane("t1").first?.gain == Gain(dB: 4))
        #expect(throws: SessionError.unknownClip("c9")) { try session.setGain(.zero, clip: "c9") }
    }

    /// K1: one batch sets each clip as one undo entry; an unknown ID changes nothing.
    @Test mutating func setGainsSetsEachClipInOnePass() throws {
        for (id, start) in [("A", 0), ("B", 48_000), ("C", 96_000)] as [(ClipID, Frames)] {
            try session.place(clip(id, start: start, length: 1_000), on: "t1")
        }
        var history = History(session)
        try history.edit { session throws(SessionError) in
            try session.setGains(["A": Gain(dB: -6)!, "C": Gain(dB: 3)!])
        }
        #expect(history.session.track("t1")?.clips.map(\.gain) == [Gain(dB: -6)!, .zero, Gain(dB: 3)!])
        try history.undo()
        #expect(history.session == session, "one undo entry restores both clips")
        #expect(history.canUndo == false)

        #expect(throws: SessionError.unknownClip("X"), "an unknown clip is refused") {
            try session.setGains(["A": Gain(dB: -6)!, "X": .zero])
        }
        #expect(session.clip("A")?.clip.gain == .zero, "a refused batch changes nothing")
    }

    // MARK: Fades (decision 0035)

    func fades(_ id: ClipID) -> Fades? { session.clip(id)?.clip.fades }

    /// The curve: a quarter sine in, its mirror out, 1 outside the fades.
    @Test func theFadeGainFollowsTheQuarterSine() throws {
        let fades = try #require(Fades(fadeIn: 480, fadeOut: 960))
        let gain = { (k: Int) in fades.gain(at: Frames(k), length: 4_800) }
        #expect(gain(0) == 0, "the first frame of a fade-in is 0")
        #expect(abs(gain(240) - 0.707_106_78) < 1e-8, "half the fade-in is -3 dB")
        #expect(gain(480) == 1 && gain(2_000) == 1, "1 between the fades")
        #expect(abs(gain(3_840) - 1) < 1e-12, "the first frame of the fade-out is 1")
        #expect(abs(gain(4_799) - sin(Double.pi / 2 / 960)) < 1e-12, "the last frame is sin(pi/2 / O)")
        #expect(abs(gain(4_320) - 0.707_106_78) < 1e-8, "half the fade-out is -3 dB")
        #expect(Fades.zero.gain(at: 0, length: 10) == 1, "no fade is 1")
    }

    /// Fades C4: the edit checks fadeIn + fadeOut <= length, and the batch is atomic.
    @Test mutating func setFadesChecksTheInvariant() throws {
        try session.place(clip("c1", start: 0, length: 1_000), on: "t1")
        try session.place(clip("c2", start: 0, length: 1_000), on: "t2")
        try session.setFades(["c1": Fades(fadeIn: 400, fadeOut: 600)!])
        #expect(fades("c1") == Fades(fadeIn: 400, fadeOut: 600), "= length passes")

        let before = session
        #expect(throws: SessionError.fadeOutsideClip("c2", length: 1_000), "length + 1 is refused") {
            try session.setFades(["c1": .zero, "c2": Fades(fadeIn: 400, fadeOut: 601)!])
        }
        #expect(throws: SessionError.unknownClip("c9"), "an unknown clip is refused") {
            try session.setFades(["c1": .zero, "c9": .zero])
        }
        #expect(session == before, "a refused batch changes nothing")
        #expect(Fades(fadeIn: -1, fadeOut: 0) == nil && Fades(fadeIn: 0, fadeOut: -1) == nil, "-1 is refused")
        #expect(Fades(fadeIn: Frames.limit + 1, fadeOut: 0) == nil, "over the limit is refused")
        #expect(Fades(fadeIn: Frames.limit, fadeOut: Frames.limit) != nil, "the limit passes")
    }

    /// Fades C6: a clip of 1 000 frames with (300, 500). An edit keeps the fade of a kept edge; the
    /// fade of a moved or new edge yields.
    @Test(arguments: [
        ("split at 400", ["a": Fades(fadeIn: 300, fadeOut: 0)!, "a@1400": Fades(fadeIn: 0, fadeOut: 500)!]),
        ("clear 400..<600", ["a": Fades(fadeIn: 300, fadeOut: 0)!, "a@1600": Fades(fadeIn: 0, fadeOut: 400)!]),
        ("trim end to 600", ["a": Fades(fadeIn: 300, fadeOut: 300)!]),
        ("trim end to 900", ["a": Fades(fadeIn: 300, fadeOut: 500)!]),
        ("trim end to 300", ["a": Fades(fadeIn: 300, fadeOut: 0)!]),
        ("trim end to 200", ["a": Fades(fadeIn: 200, fadeOut: 0)!]),
        ("trim start to 600", ["a": Fades(fadeIn: 100, fadeOut: 500)!]),
        ("extend", ["a": Fades(fadeIn: 300, fadeOut: 500)!]),
        ("move", ["a": Fades(fadeIn: 300, fadeOut: 500)!]),
        ("nudge", ["a": Fades(fadeIn: 300, fadeOut: 500)!]),
        (
            "excerpt 0..<400 and paste",
            ["a": Fades(fadeIn: 300, fadeOut: 500)!, "a@5000": Fades(fadeIn: 300, fadeOut: 0)!]
        ),
    ])
    func editsKeepTheFadeOfAKeptEdge(edit: String, expected: [ClipID: Fades]) throws {
        var session = self.session
        try session.place(clip("a", start: 1_000, offset: 1_000, length: 1_000), on: "t1")
        try session.setFades(["a": Fades(fadeIn: 300, fadeOut: 500)!])
        switch edit {
        case "split at 400": try session.split("a", at: 1_400)
        case "clear 400..<600": try session.clear(1_400..<1_600, on: "t1")
        case "trim end to 600": try session.trim("a", to: 1_000..<1_600)
        case "trim end to 900": try session.trim("a", to: 1_000..<1_900)
        case "trim end to 300": try session.trim("a", to: 1_000..<1_300)
        case "trim end to 200": try session.trim("a", to: 1_000..<1_200)
        case "trim start to 600": try session.trim("a", to: 1_400..<2_000)
        case "extend": try session.trim("a", to: 500..<2_500)
        case "move": try session.move("a", to: "t2", start: 3_000)
        case "nudge": try session.nudge(["a"], by: 480)
        default:
            let excerpt = try session.excerpt(of: 1_000..<1_400, on: ["t1"])
            try session.paste(excerpt, at: 5_000, on: ["t1"])
        }
        let found = Dictionary(uniqueKeysWithValues: session.tracks.flatMap(\.clips).map { ($0.id, $0.fades) })
        #expect(found == expected, "\(edit)")
    }
}
