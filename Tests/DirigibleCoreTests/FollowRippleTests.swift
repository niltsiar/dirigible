import Foundation
import Testing

@testable import DirigibleCore

/// The follow rule in the ripple edits (decision 0073) on fixture F: track `host` with h
/// 0 ..< 960 000, track `bed` (follows) with bed 0 ..< 960 000, and track `sfx` (follows) with w at
/// 192 000 (24 000), x at 264 000 (12 000), and y at 360 000 (48 000). The cut is 240 000 ..< 336 000.
struct FollowRippleTests {
    static let cut: Range<Frames> = 240_000..<336_000
    var session: Session

    init() throws {
        session = try Self.fixture()
    }

    static func fixture(w: Frames = 24_000, follow: [TrackID] = ["bed", "sfx"]) throws -> Session {
        var session = Session(sampleRate: 48_000)
        for (track, file) in [("host", "h"), ("bed", "b"), ("sfx", "s")] {
            try session.addTrack(TrackID(track), name: track, layout: .mono)
            try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: 1_000_000))
        }
        try session.place(Clip(id: "h", file: "h", start: 0, offset: 0, length: 960_000), on: "host")
        try session.place(Clip(id: "bed", file: "b", start: 0, offset: 0, length: 960_000), on: "bed")
        try session.setClips(
            [
                Clip(id: "w", file: "s", start: 192_000, offset: 0, length: w),
                Clip(id: "x", file: "s", start: 264_000, offset: 100_000, length: 12_000),
                Clip(id: "y", file: "s", start: 360_000, offset: 200_000, length: 48_000),
            ], on: "sfx")
        try session.setFollowTrack(true, tracks: follow)
        return session
    }

    var all: [TrackID] { session.tracks.map(\.id) }

    func starts(_ track: TrackID, in session: Session? = nil) -> [ClipID: Frames] {
        Dictionary(
            uniqueKeysWithValues: ((session ?? self.session).track(track)?.clips ?? ClipLane()).map {
                ($0.id, $0.start)
            })
    }

    func lane(_ track: TrackID, in session: Session? = nil) -> [Clip] {
        Array((session ?? self.session).track(track)?.clips ?? ClipLane())
    }

    /// C32: the bed stays whole with its ID, and the sfx starts map by Rule M; the flag off cuts the bed.
    @Test mutating func aFollowClipAfterTheCutMovesWholeAndNoneSplits() throws {
        var plain = try Self.fixture(follow: [])
        try session.rippleDelete(Self.cut, on: all)
        try plain.rippleDelete(Self.cut, on: plain.tracks.map(\.id))

        #expect(lane("bed").map(\.id) == ["bed"] && lane("bed")[0].range == 0..<960_000)
        #expect(starts("sfx") == ["w": 192_000, "x": 240_000, "y": 264_000])
        #expect(lane("bed", in: plain).count == 2, "the control: with the flag off the bed is cut in two")
    }

    /// C32: the host track cuts and closes as with no flag.
    @Test mutating func theOtherTracksCutAsBefore() throws {
        var plain = try Self.fixture(follow: [])
        try session.rippleDelete(Self.cut, on: all)
        try plain.rippleDelete(Self.cut, on: plain.tracks.map(\.id))

        #expect(lane("host") == lane("host", in: plain))
        #expect(lane("host").map(\.range) == [0..<240_000, 240_000..<864_000])
    }

    /// C32: two ranges map each start by Rule M.
    @Test mutating func severalRangesMapEachStartByRuleM() throws {
        try session.setClips(
            [105_000, 220_000, 250_000].map {
                Clip(id: ClipID("c\($0)"), file: "s", start: $0, offset: 0, length: 1_000)
            },
            on: "sfx")

        try session.rippleDelete([100_000..<110_000, 200_000..<230_000], on: all)

        #expect(starts("sfx") == ["c105000": 100_000, "c220000": 190_000, "c250000": 210_000])
    }

    /// C33: each pair passes and fails; a refusal changes nothing on any track.
    @Test func aFollowOverlapRefusesTheWholeRipple() throws {
        var touching = try Self.fixture(w: 48_000)
        try touching.rippleDelete(Self.cut, on: touching.tracks.map(\.id))
        #expect(starts("sfx", in: touching) == ["w": 192_000, "x": 240_000, "y": 264_000], "x touches w")

        var over = try Self.fixture(w: 48_001)
        let before = over
        #expect(throws: SessionError.followOverlap("x", "w")) {
            try over.rippleDelete(Self.cut, on: before.tracks.map(\.id))
        }
        #expect(over == before)

        for (q, result) in [(Frames(260_000), nil), (340_000, Frames(244_000))] {
            var two = try Self.fixture()
            try two.setClips(
                [
                    Clip(id: "p", file: "s", start: 250_000, offset: 0, length: 4_000),
                    Clip(id: "q", file: "s", start: q, offset: 0, length: 4_000),
                ], on: "sfx")
            let twoBefore = two
            if let result {
                try two.rippleDelete(Self.cut, on: two.tracks.map(\.id))
                #expect(starts("sfx", in: two) == ["p": 240_000, "q": result])
            } else {
                #expect(throws: SessionError.followOverlap("q", "p")) {
                    try two.rippleDelete(Self.cut, on: twoBefore.tracks.map(\.id))
                }
                #expect(two == twoBefore)
            }
        }

        for (range, refuses) in [(Self.cut, true), (300_000..<336_000, false)] {
            var pair = try Self.fixture()
            try pair.setClips(
                [
                    Clip(id: "m1", file: "s", start: 0, offset: 0, length: 300_000),
                    Clip(id: "m2", file: "s", start: 300_000, offset: 300_000, length: 300_000),
                ], on: "sfx")
            let pairBefore = pair
            if refuses {
                #expect(throws: SessionError.followOverlap("m2", "m1")) {
                    try pair.rippleDelete(range, on: pairBefore.tracks.map(\.id))
                }
                #expect(pair == pairBefore)
            } else {
                try pair.rippleDelete(range, on: pair.tracks.map(\.id))
                #expect(starts("sfx", in: pair) == ["m1": 0, "m2": 300_000])
            }
        }
    }

    /// C34: an insert splits no follow clip and moves each clip at or after the frame; the flag off
    /// splits the bed.
    @Test mutating func anInsertKeepsAFollowClipWhole() throws {
        try session.place(Clip(id: "z", file: "b", start: 970_000, offset: 970_000, length: 10_000), on: "bed")
        try session.setClips([Clip(id: "a", file: "s", start: 300_000, offset: 0, length: 1_000)], on: "sfx")
        var plain = session
        try plain.setFollowTrack(false, tracks: ["bed", "sfx"])

        try session.rippleInsert(48_000, at: 300_000, on: all)
        try plain.rippleInsert(48_000, at: 300_000, on: plain.tracks.map(\.id))

        #expect(starts("bed") == ["bed": 0, "z": 1_018_000] && lane("bed")[0].length == 960_000)
        #expect(starts("sfx") == ["a": 348_000])
        #expect(lane("bed", in: plain).count == 3, "the control: with the flag off the bed splits")
    }

    /// C34 (0036): an insert inside the first clip of a touching pair opens the join, and both clips
    /// lose its crossfade.
    @Test mutating func aFollowInsertInsideTheFirstClipOpensTheJoin() throws {
        try session.setClips(
            [
                Clip(id: "m1", file: "s", start: 0, offset: 0, length: 300_000),
                Clip(id: "m2", file: "s", start: 300_000, offset: 400_000, length: 300_000),
            ], on: "sfx")
        try session.setCrossfades(["m1": 960])
        #expect(lane("sfx").map(\.crossfades.end) == [960, .zero])

        try session.rippleInsert(48_000, at: 100_000, on: all)

        #expect(starts("sfx") == ["m1": 0, "m2": 348_000])
        #expect(lane("sfx").allSatisfy { $0.crossfades == .zero })
    }

    /// C35: a trim of the end of a host clip deletes the span on the follow lane by Rule M; a cover
    /// refuses and changes nothing.
    @Test func aRippleTrimMovesTheFollowLanes() throws {
        for (v, refuses) in [(Frames(100_000), false), (180_000, false), (185_000, true)] {
            var trim = try Self.fixture()
            try trim.setClips([Clip(id: "hc", file: "h", start: 200_000, offset: 0, length: 100_000)], on: "host")
            try trim.setClips(
                [
                    Clip(id: "v", file: "s", start: 100_000, offset: 0, length: v),
                    Clip(id: "u", file: "s", start: 290_000, offset: 300_000, length: 10_000),
                    Clip(id: "t", file: "s", start: 400_000, offset: 400_000, length: 10_000),
                ], on: "sfx")
            let before = trim
            if refuses {
                #expect(throws: SessionError.followOverlap("u", "v")) {
                    try trim.rippleTrim("hc", edge: .end, by: -20_000, on: before.tracks.map(\.id))
                }
                #expect(trim == before)
            } else {
                try trim.rippleTrim("hc", edge: .end, by: -20_000, on: trim.tracks.map(\.id))
                #expect(starts("sfx", in: trim) == ["v": 100_000, "u": 280_000, "t": 380_000], "v \(v)")
                #expect(lane("bed", in: trim).count == 1)
            }
        }
        var longer = try Self.fixture()
        try longer.setClips([Clip(id: "hc", file: "h", start: 200_000, offset: 0, length: 100_000)], on: "host")
        try longer.rippleTrim("hc", edge: .end, by: 20_000, on: longer.tracks.map(\.id))
        #expect(starts("sfx", in: longer) == ["w": 192_000, "x": 264_000, "y": 380_000], "a longer clip never refuses")
    }

    /// C36: each Core ripple entry point refuses the follow overlap and changes nothing.
    @Test func everyRippleEntryPointRefusesAFollowOverlap() throws {
        var base = try Self.fixture(w: 48_001)
        base.addWords([(1, Self.cut, "word")], file: "h")
        let excerpt = try base.excerpt(of: 0..<48_000, on: ["host"])
        let plan = try SilencePlan([SilenceEdit(range: 239_750..<336_250, action: .shorten)], keep: 500)
        let edits: [(String, (inout Session) throws -> Void)] = [
            ("rippleDelete", { try $0.rippleDelete(Self.cut, on: $0.tracks.map(\.id)) }),
            ("replace", { try $0.replace(Self.cut, with: excerpt, on: ["host"]) }),
            ("cutWords", { try $0.cutWords($0.occurrences([1])) }),
            ("editSilences", { try $0.editSilences(plan, muting: []) }),
        ]
        for (name, edit) in edits {
            var session = base
            #expect(throws: SessionError.followOverlap("x", "w"), "\(name)") { try edit(&session) }
            #expect(session == base, "\(name)")
        }
    }

    /// C51: a named follow lane cuts as a normal lane, and the other follow lane still follows.
    @Test mutating func aNamedFollowLaneCutsAsANormalLane() throws {
        try session.rippleDelete(Self.cut, on: all, naming: ["bed"])

        #expect(lane("bed").map(\.range) == [0..<240_000, 240_000..<864_000])
        #expect(lane("bed")[1].offset == 336_000)
        #expect(starts("sfx") == ["w": 192_000, "x": 240_000, "y": 264_000])
    }

    /// C51: with the flag on host too, a cut word of host cuts host as with no flag, and the bed stays.
    @Test func aCutWordOnAFollowTrackCutsThatTrack() throws {
        var session = try Self.fixture(follow: ["bed", "sfx", "host"])
        session.addWords([(1, Self.cut, "word")], file: "h")
        var plain = try Self.fixture(follow: [])
        plain.addWords([(1, Self.cut, "word")], file: "h")

        #expect(try session.cutWords(session.occurrences([1])) == [Self.cut])
        _ = try plain.cutWords(plain.occurrences([1]))

        #expect(lane("host", in: session) == lane("host", in: plain))
        #expect(lane("bed", in: session).map(\.id) == ["bed"])
        #expect(starts("sfx", in: session) == ["w": 192_000, "x": 240_000, "y": 264_000])
    }

    /// C55: with each track following and no named track, a delete, an insert, and a silence Cut
    /// throw `.noRippleTrack` and change nothing; a named track, a trim, a Mark and Mute Apply, no
    /// range, and a length of 0 pass.
    @Test func aRippleWithOnlyFollowLanesRefuses() throws {
        let base = try Self.fixture(follow: ["host", "bed", "sfx"])
        let ids = base.tracks.map(\.id)
        let cuts = try SilencePlan([SilenceEdit(range: 239_750..<336_250, action: .shorten)], keep: 500)
        let refused: [(String, (inout Session) throws -> Void)] = [
            ("delete", { try $0.rippleDelete(Self.cut, on: ids) }),
            ("insert", { try $0.rippleInsert(48_000, at: 300_000, on: ids) }),
            ("silences", { try $0.editSilences(cuts, muting: []) }),
        ]
        for (name, edit) in refused {
            var session = base
            #expect(throws: SessionError.noRippleTrack, "\(name)") { try edit(&session) }
            #expect(session == base, "\(name)")
        }

        var named = base
        try named.rippleDelete(Self.cut, on: ids, naming: ["host"])
        #expect(lane("host", in: named).map(\.range) == [0..<240_000, 240_000..<864_000])
        #expect(lane("bed", in: named).map(\.id) == ["bed"])
        #expect(starts("sfx", in: named) == ["w": 192_000, "x": 240_000, "y": 264_000])
        var inserted = base
        try inserted.rippleInsert(48_000, at: 300_000, on: ids, naming: ["host"])
        #expect(lane("host", in: inserted).count == 2)
        var trimmed = base
        try trimmed.rippleTrim("h", edge: .end, by: -20_000, on: ids)
        #expect(lane("host", in: trimmed)[0].length == 940_000)

        var marked = base
        let marks = try SilencePlan(
            [
                SilenceEdit(range: 100_000..<200_000, action: .mark(name: "pause")),
                SilenceEdit(range: 500_000..<600_000, action: .mute),
            ], keep: nil)
        let result = try marked.editSilences(marks, muting: ["host"])
        #expect(result.markers.count == 1 && result.cuts.isEmpty)
        #expect(lane("sfx", in: marked) == lane("sfx", in: base))

        var still = base
        try still.rippleDelete([], on: ids)
        try still.rippleInsert(.zero, at: 300_000, on: ids)
        try still.editSilences(try SilencePlan([], keep: nil), muting: [])
        #expect(still == base)
    }

    /// C52: Insert onto the bed names it, so the insert splits the bed and the paste fills the gap.
    @Test func anInsertOntoAFollowTrackKeepsEachFrame() throws {
        var lanes: [[Clip]] = []
        for follow: [TrackID] in [["bed", "sfx"], []] {
            var session = try Self.fixture(follow: follow)
            let excerpt = try session.excerpt(of: 0..<48_000, on: ["host"])
            try session.rippleInsert(excerpt.length, at: 300_000, on: session.tracks.map(\.id), naming: ["bed"])
            let pasted = try session.paste(excerpt, at: 300_000, on: ["bed"])
            #expect(pasted.count == 1)
            lanes.append(lane("bed", in: session))
            if !follow.isEmpty { #expect(starts("sfx", in: session) == ["w": 192_000, "x": 264_000, "y": 408_000]) }
        }
        #expect(lanes[0].map(\.range) == [0..<300_000, 300_000..<348_000, 348_000..<1_008_000])
        #expect(lanes[0][2].offset == 300_000)
        #expect(lanes[0] == lanes[1], "the bed lane equals the lane of the same paste with the flag off")
    }

    /// C52: Replace onto the bed names it, so no frame of the bed is lost.
    @Test func aReplaceOntoAFollowTrackKeepsEachFrame() throws {
        var lanes: [[Clip]] = []
        for follow: [TrackID] in [["bed", "sfx"], []] {
            var session = try Self.fixture(follow: follow)
            let excerpt = try session.excerpt(of: 0..<48_000, on: ["host"])
            try session.replace(Self.cut, with: excerpt, on: ["bed"])
            lanes.append(lane("bed", in: session))
            if !follow.isEmpty { #expect(starts("sfx", in: session) == ["w": 192_000, "x": 240_000, "y": 312_000]) }
        }
        #expect(lanes[0].map(\.range) == [0..<240_000, 240_000..<288_000, 288_000..<912_000])
        #expect(lanes[0][2].offset == 336_000)
        #expect(lanes[0] == lanes[1])
    }

    /// Code gate 3 item 2: after a Replace onto `host`, the follow clip x from inside the cut and a
    /// marker at its start both start at the cut start, and the bed stays whole. A clip z at the cut
    /// end moves with the later clips, by the excerpt length minus the cut length.
    @Test mutating func aReplaceMovesAFollowClipInTheRangeToTheRangeStartAsAMarker() throws {
        try session.setMarker(Marker(id: "m", name: "m", position: 264_000, kind: .marker))
        let excerpt = try session.excerpt(of: 0..<48_000, on: ["host"])
        var replaced = session
        try replaced.replace(Self.cut, with: excerpt, on: ["host"])
        #expect(starts("sfx", in: replaced) == ["w": 192_000, "x": 240_000, "y": 312_000])
        #expect(replaced.markers["m"]?.position == 240_000)
        #expect(lane("bed", in: replaced).map(\.range) == [0..<960_000])
        try session.place(Clip(id: "z", file: "s", start: 336_000, offset: 300_000, length: 12_000), on: "sfx")
        try session.replace(Self.cut, with: excerpt, on: ["host"])
        #expect(starts("sfx") == ["w": 192_000, "x": 240_000, "z": 288_000, "y": 312_000])
    }

    /// C32 (U29): over seeded random follow lanes and 1 to 3 ranges, a refusal changes nothing, and
    /// a pass keeps each ID and length, the order with no overlap, and each touching pair touching.
    @Test(arguments: [UInt64(1), 2, 3, 4])
    func aLegalFollowDeleteKeepsEachJoin(seed: UInt64) throws {
        var random = SplitMix(seed: seed)
        var (passed, refused) = (0, 0)
        for _ in 0..<300 {
            var session = Session(sampleRate: 48_000)
            try session.addTrack("f", name: "f", layout: .mono)
            try session.addTrack("n", name: "n", layout: .mono)
            try session.addFile(AudioFile(id: "s", path: "s.wav", layout: .mono, length: 1_000_000))
            var clips: [Clip] = []
            var at = Frames(Int.random(in: 0..<1_000, using: &random))
            for index in 0..<Int.random(in: 1...6, using: &random) {
                if Bool.random(using: &random) { at = at + Frames(Int.random(in: 1..<2_000, using: &random)) }
                let length = Frames(Int.random(in: 1..<3_000, using: &random))
                clips.append(Clip(id: ClipID("c\(index)"), file: "s", start: at, offset: 0, length: length))
                at = at + length
            }
            try session.setClips(clips, on: "f")
            try session.setFollowTrack(true, tracks: ["f"])
            var ranges: [Range<Frames>] = []
            for _ in 0..<Int.random(in: 1...3, using: &random) {
                let start = Int.random(in: 0..<at.count + 500, using: &random)
                ranges.append(Frames(start)..<Frames(start + Int.random(in: 1..<2_000, using: &random)))
            }
            let before = session
            do {
                try session.rippleDelete(ranges, on: ["f", "n"])
            } catch {
                refused += 1
                #expect(isFollowOverlap(error), "\(error)")
                #expect(session == before)
                continue
            }
            passed += 1
            let old = Array(before.track("f")!.clips)
            let new = Array(session.track("f")!.clips)
            #expect(new.map(\.id) == old.map(\.id) && new.map(\.length) == old.map(\.length), "no split")
            for index in new.indices.dropFirst() {
                #expect(new[index - 1].end <= new[index].start, "the order with no overlap")
                if old[index - 1].end == old[index].start {
                    #expect(new[index - 1].end == new[index].start, "a touching pair stays touching")
                }
            }
        }
        #expect(passed > 0 && refused > 0, "passed \(passed), refused \(refused)")
    }

    func isFollowOverlap(_ error: SessionError) -> Bool {
        if case .followOverlap = error { true } else { false }
    }
}
