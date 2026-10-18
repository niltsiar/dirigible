import Foundation
import Testing

@testable import DirigibleCore

/// Crossfades at a butt join (decision 0036). Tracks "t1" and "t2" (mono). Clip A on file "fa" and clip B on
/// file "fb", each file 10 000 frames. A is 1 000 ..< 5 000 at offset 1 000, B is 5 000 ..< 9 000 at
/// offset 1 000, so the join J is 5 000 with 5 000 frames of handle after A and 1 000 before B.
struct CrossfadeTests {
    var session: Session

    init() throws {
        session = Session(sampleRate: 48_000)
        for id in ["fa", "fb"] as [FileID] {
            try session.addFile(AudioFile(id: id, path: "\(id).wav", layout: .mono, length: 10_000))
        }
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
    }

    /// Places A and B with the given changes, on a session with no other clips.
    mutating func join(a: (inout Clip) -> Void = { _ in }, b: (inout Clip) -> Void = { _ in }) throws {
        var clipA = Clip(id: "A", file: "fa", start: 1_000, offset: 1_000, length: 4_000)
        var clipB = Clip(id: "B", file: "fb", start: 5_000, offset: 1_000, length: 4_000)
        a(&clipA)
        b(&clipB)
        try session.place(clipA, on: "t1")
        try session.place(clipB, on: "t1")
    }

    func crossfades(_ id: ClipID) -> Crossfades? { session.clip(id)?.clip.crossfades }
    func fades(_ id: ClipID) -> Fades? { session.clip(id)?.clip.fades }

    /// The lane form of `crossfadeLimit` for the clip `id`; nil when no lane holds it.
    func limit(after id: ClipID) -> Frames? {
        guard let (track, index) = try? session.position(of: id) else { return nil }
        return session.crossfadeLimit(after: index, in: session.tracks[track].clips)
    }

    /// All crossfades of the lanes, by clip ID; a clip with none is left out.
    var allCrossfades: [ClipID: Crossfades] {
        Dictionary(
            uniqueKeysWithValues: session.tracks.flatMap(\.clips).filter { $0.crossfades != .zero }.map {
                ($0.id, $0.crossfades)
            })
    }

    @Test func aCrossfadeLengthIsEvenAndInRange() {
        #expect(Crossfades(start: 960, end: 0) != nil && Crossfades(start: 0, end: Frames.limit) != nil)
        #expect(Crossfades(start: 961, end: 0) == nil && Crossfades(start: 0, end: 3) == nil, "odd is refused")
        #expect(Crossfades(start: -2, end: 0) == nil, "negative is refused")
        #expect(Crossfades(start: 0, end: Frames.limit + 2) == nil, "over the limit is refused")
    }

    /// F2: each side of the media-handle limit, the join rule, and the room rule.
    @Test mutating func theHandleLimit() throws {
        try join(b: { $0.offset = 480 })
        #expect(throws: Never.self, "B with 480 frames of handle passes") { try session.setCrossfades(["A": 960]) }
        #expect(crossfades("A") == Crossfades(start: 0, end: 960), "B with 480 frames of handle passes (A)")
        #expect(crossfades("B") == Crossfades(start: 960, end: 0), "B with 480 frames of handle passes (B)")

        var short = try CrossfadeTests()
        try short.join(b: { $0.offset = 479 })
        let before = short.session
        #expect(throws: SessionError.crossfadeOutsideFile("B", needed: 480), "B with 479 frames is refused") {
            try short.session.setCrossfades(["A": 960])
        }
        #expect(short.session == before, "a refused crossfade changes nothing")

        // A side: offset + length + L/2 against the file length.
        var fits = try CrossfadeTests()
        try fits.session.addFile(AudioFile(id: "fs", path: "fs.wav", layout: .mono, length: 5_480))
        try fits.join(a: { $0.file = "fs" })
        #expect(throws: Never.self, "A with offset + length + 480 = file length passes") {
            try fits.session.setCrossfades(["A": 960])
        }
        #expect(fits.crossfades("A")?.end == 960, "A with offset + length + 480 = file length passes")

        var tight = try CrossfadeTests()
        try tight.session.addFile(AudioFile(id: "fs", path: "fs.wav", layout: .mono, length: 5_479))
        try tight.join(a: { $0.file = "fs" })
        #expect(throws: SessionError.crossfadeOutsideFile("A", needed: 480), "1 frame less of file is refused") {
            try tight.session.setCrossfades(["A": 960])
        }

        #expect(throws: SessionError.crossfadeWithoutJoin("B"), "no clip touches the end of B") {
            try session.setCrossfades(["B": 960])
        }
        #expect(throws: SessionError.unknownClip("Z"), "an unknown clip is refused") {
            try session.setCrossfades(["Z": 960])
        }
        #expect(throws: SessionError.frameOutOfRange, "an odd length is refused") {
            try session.setCrossfades(["A": 961])
        }
    }

    /// The lane form of `setCrossfades` keeps the join rule, and a throw changes nothing.
    @Test mutating func theLaneFormRefusesAClipWithNoJoin() throws {
        try join()
        let before = session
        #expect(throws: SessionError.crossfadeWithoutJoin("B"), "no clip touches the end of B") {
            try session.setCrossfades(lanes: [0: [(index: 0, length: 960), (index: 1, length: 960)]])
        }
        #expect(session == before)
    }

    /// F2: a crossfade whose half does not fit beside the crossfade at the other edge is refused; a
    /// fade at the other edge yields first.
    @Test mutating func theRoomOfAClip() throws {
        try join(b: { $0.length = 1_000 })
        try session.place(Clip(id: "C", file: "fa", start: 6_000, offset: 6_000, length: 3_000), on: "t1")
        try session.setCrossfades(["A": 1_000])
        #expect(throws: SessionError.fadeOutsideClip("B", length: 1_000), "500 + 501 > 1 000 is refused") {
            try session.setCrossfades(["B": 1_002])
        }
        try session.setCrossfades(["B": 1_000])
        #expect(crossfades("B") == Crossfades(start: 1_000, end: 1_000), "500 + 500 = 1 000 passes")

        var yielding = try CrossfadeTests()
        try yielding.join(a: { $0.fades = Fades(fadeIn: 3_800, fadeOut: 0)! })
        try yielding.session.setCrossfades(["A": 960])
        #expect(yielding.fades("A") == Fades(fadeIn: 3_520, fadeOut: 0), "the fade-in yields to length - L/2")
    }

    /// F2: `crossfadeLimit` is 2 x min(handle after A, handle before B, room in A, room in B), with
    /// one case where each bound is the smallest.
    @Test func theLimitTakesTheSmallestBound() throws {
        func limit(a: @escaping (inout Clip) -> Void = { _ in }, b: @escaping (inout Clip) -> Void = { _ in })
            throws -> Frames?
        {
            var test = try CrossfadeTests()
            try test.session.addFile(AudioFile(id: "fs", path: "fs.wav", layout: .mono, length: 5_300))
            try test.join(a: a, b: b)
            return test.limit(after: "A")
        }
        #expect(try limit(a: { $0.file = "fs" }) == 600, "handle after A: 300")
        #expect(try limit(b: { $0.offset = 200 }) == 400, "handle before B: 200")
        #expect(
            try limit(a: { ($0.start, $0.length, $0.fades) = (4_750, 250, Fades(fadeIn: 200, fadeOut: 0)!) }) == 500,
            "room in A: 250, its fade yields")
        #expect(try limit(b: { $0.length = 150 }) == 300, "room in B: 150")
        #expect(try limit() == 2_000, "no bound under 1 000: the handle before B")
        #expect(try limit(b: { ($0.file, $0.offset) = ("fa", 6_000) }) == 8_000, "one file with a gap of offsets")

        var test = try CrossfadeTests()
        try test.join()
        try test.session.setCrossfades(["A": 960])
        #expect(test.limit(after: "A") == 2_000, "A's own crossfade does not bound the limit")
        #expect(test.limit(after: "B") == nil, "no join after B")

        var seamless = try CrossfadeTests()
        try seamless.join(b: { ($0.file, $0.offset) = ("fa", 5_000) })
        #expect(seamless.limit(after: "A") == 8_000, "a seamless join: the rooms of A and B")
        #expect(throws: SessionError.crossfadeAtEqualGains("A"), "a seamless join with equal gains is refused") {
            try seamless.session.setCrossfades(["A": 960])
        }
    }

    /// F3: the crossfade replaces the fades at its two edges; L = 0 removes it from both clips.
    @Test mutating func aCrossfadeReplacesTheEdgeFades() throws {
        try join(
            a: { $0.fades = Fades(fadeIn: 200, fadeOut: 300)! }, b: { $0.fades = Fades(fadeIn: 400, fadeOut: 100)! })
        try session.setCrossfades(["A": 960])
        #expect(fades("A") == Fades(fadeIn: 200, fadeOut: 0), "A's fade-out goes to 0")
        #expect(fades("B") == Fades(fadeIn: 0, fadeOut: 100), "B's fade-in goes to 0")
        let before = session
        #expect(throws: SessionError.fadeAtCrossfade("A"), "a fade at a crossfade edge is refused") {
            try session.setFades(["A": Fades(fadeIn: 200, fadeOut: 10)!])
        }
        #expect(session == before)
        try session.setCrossfades(["A": 0])
        #expect(allCrossfades.isEmpty, "L = 0 removes the crossfade from both clips")
        #expect(fades("A") == Fades(fadeIn: 200, fadeOut: 0) && fades("B") == Fades(fadeIn: 0, fadeOut: 100))
    }

    /// F4: each edit that breaks the join drops the crossfade from both clips; each edit that keeps
    /// it keeps it on both.
    @Test(
        arguments: [
            ("move A", [:]),
            ("move A to t2", [:]),
            ("move B to t2", [:]),
            ("trim A's end", [:]),
            ("trim B's start", [:]),
            ("clear over J", [:]),
            ("delete A", [:]),
            ("delete B", [:]),
            ("paste B alone", ["A": Crossfades(start: 0, end: 960)!, "B": Crossfades(start: 960, end: 0)!]),
            ("split inside A's last L/2", [:]),
            ("split inside B's first L/2", [:]),
            ("nudge B alone", [:]),
            ("place a clip at J", [:]),
            ("nudge A and B", ["A": Crossfades(start: 0, end: 960)!, "B": Crossfades(start: 960, end: 0)!]),
            (
                "paste A and B",
                [
                    "A": Crossfades(start: 0, end: 960)!, "B": Crossfades(start: 960, end: 0)!,
                    "A@19000": Crossfades(start: 0, end: 960)!, "B@22000": Crossfades(start: 960, end: 0)!,
                ]
            ),
            (
                "split outside the reaches",
                ["A@3000": Crossfades(start: 0, end: 960)!, "B": Crossfades(start: 960, end: 0)!]
            ),
            ("trim A's start", ["A": Crossfades(start: 0, end: 960)!, "B": Crossfades(start: 960, end: 0)!]),
            ("move A to its own place", ["A": Crossfades(start: 0, end: 960)!, "B": Crossfades(start: 960, end: 0)!]),
            ("nudge A alone by 0", ["A": Crossfades(start: 0, end: 960)!, "B": Crossfades(start: 960, end: 0)!]),
        ] as [(String, [ClipID: Crossfades])])
    mutating func anEditThatBreaksAJoinDropsTheCrossfade(edit: String, expected: [ClipID: Crossfades]) throws {
        try join()
        try session.setCrossfades(["A": 960])
        switch edit {
        case "move A": try session.move("A", to: "t1", start: 0)
        case "move A to t2": try session.move("A", to: "t2", start: 1_000)
        case "move B to t2": try session.move("B", to: "t2", start: 5_000)
        case "trim A's end": try session.trim("A", to: 1_000..<4_500)
        case "trim B's start": try session.trim("B", to: 5_500..<9_000)
        case "clear over J": try session.clear(4_900..<5_100, on: ["t1"])
        case "delete A": try session.clear(1_000..<5_000, on: ["t1"])
        case "delete B": try session.clear(5_000..<9_000, on: ["t1"])
        case "paste B alone":
            try session.paste(try session.excerpt(of: 5_000..<9_000, on: ["t1"]), at: 20_000, on: ["t1"])
        case "split inside A's last L/2": try session.split("A", at: 4_800)
        case "split inside B's first L/2": try session.split("B", at: 5_200)
        case "nudge B alone": try session.nudge(["B"], by: 100)
        case "place a clip at J":
            try session.place(Clip(id: "T", file: "fa", start: 4_800, offset: 0, length: 400), on: "t1")
        case "nudge A and B": try session.nudge(["A", "B"], by: 1_000)
        case "paste A and B":
            try session.paste(try session.excerpt(of: 2_000..<8_000, on: ["t1"]), at: 19_000, on: ["t1"])
        case "split outside the reaches": try session.split("A", at: 3_000)
        case "trim A's start": try session.trim("A", to: 2_000..<5_000)
        case "move A to its own place": try session.move("A", to: "t1", start: 1_000)
        case "nudge A alone by 0": try session.nudge(["A"], by: 0)
        default: Issue.record("no edit \(edit)")
        }
        #expect(allCrossfades == expected, "\(edit): the crossfades after the edit")
        #expect((try? session.checkedData()) != nil, "\(edit): the session saves")
    }

    /// F4: a trim of A's start keeps the crossfade; the fade-in yields to length - L/2, and a trim
    /// that leaves less than L/2 is refused.
    @Test mutating func aTrimBesideACrossfadeKeepsItsHalf() throws {
        try join(a: { $0.fades = Fades(fadeIn: 3_000, fadeOut: 0)! })
        try session.setCrossfades(["A": 960])
        try session.trim("A", to: 2_000..<5_000)
        #expect(fades("A") == Fades(fadeIn: 2_520, fadeOut: 0), "the fade-in yields to 3 000 - 480")
        #expect(crossfades("A") == Crossfades(start: 0, end: 960))
        #expect(throws: SessionError.fadeOutsideClip("A", length: 479), "479 frames cannot hold the half of 480") {
            try session.trim("A", to: 4_521..<5_000)
        }
        try session.trim("A", to: 4_520..<5_000)
        #expect(fades("A") == .zero && crossfades("A") == Crossfades(start: 0, end: 960), "480 frames pass")
    }

    /// F4: two joins of one clip in one call (C between A and B), and a lane with a crossfade at
    /// each join, saves and reads back.
    @Test mutating func aBatchSetsEachJoinOnce() throws {
        try join(b: { $0.start = 7_000 })
        try session.place(Clip(id: "C", file: "fb", start: 5_000, offset: 5_000, length: 2_000), on: "t1")
        try session.setCrossfades(["A": 960, "C": 480])
        #expect(
            allCrossfades
                == [
                    "A": Crossfades(start: 0, end: 960)!, "C": Crossfades(start: 960, end: 480)!,
                    "B": Crossfades(start: 480, end: 0)!,
                ], "both joins of C in one call")
        #expect(try Session(xml: try session.checkedData()) == session)
    }

    /// F4: after random edits on a lane with crossfades, each crossfade has its partner and the
    /// session saves. A refused edit changes nothing. The edits include the ripples of 0037 (C5) and
    /// clip gains. Seamless crossfade C32: each sounding edge curve is the curve of its join, and a
    /// session with a seamless crossfade reads back equal.
    @Test func randomEditsKeepTheSessionSavable() throws {
        var (withCrossfade, seamless, wrongCurves) = (0, 0, 0)
        var done: [String: Int] = [:]
        for seed in 1...500 {
            var random = SplitMix(seed: UInt64(seed))
            var session = Session(sampleRate: 48_000)
            for id in ["fa", "fb"] as [FileID] {
                try session.addFile(AudioFile(id: id, path: "\(id).wav", layout: .mono, length: 60_000))
            }
            try session.addTrack("t1", name: "Host", layout: .mono)
            // c1 plays on in the file of c0 at -6 dB: a seamless join with two gains (C32).
            for index in 0..<4 {
                let (file, offset): (FileID, Frames) =
                    index == 1 ? ("fa", 15_000) : (index % 2 == 0 ? "fa" : "fb", 10_000)
                try session.place(
                    Clip(
                        id: ClipID("c\(index)"), file: file, start: Frames(index * 5_000), offset: offset,
                        length: 5_000,
                        gain: index == 1 ? Gain(dB: -6)! : .zero),
                    on: "t1")
            }
            func frame(_ range: ClosedRange<Int>) -> Frames { Frames(Int.random(in: range, using: &random)) }
            func anyClip() -> Clip? { session.tracks[0].clips.randomElement(using: &random) }
            for step in 0..<6 {
                let before = session
                if session.tracks[0].clips.contains(where: { $0.crossfades != .zero }) { withCrossfade += 1 }
                let kind = step < 2 ? 8 : Int.random(in: 0..<12, using: &random)
                do {
                    switch kind {
                    case 0:
                        let file: FileID = Bool.random(using: &random) ? "fa" : "fb"
                        let clip = Clip(
                            id: ClipID("p\(step)"), file: file, start: frame(0...22_000), offset: frame(0...30_000),
                            length: frame(1...8_000))
                        try session.place(clip, on: "t1")
                        done["place", default: 0] += 1
                    case 1:
                        let start = frame(0...22_000)
                        try session.clear(start..<(start + frame(1...3_000)), on: ["t1"])
                        done["clear", default: 0] += 1
                    case 2:
                        let start = frame(0...20_000)
                        let excerpt = try session.excerpt(of: start..<(start + frame(1...8_000)), on: ["t1"])
                        try session.paste(excerpt, at: frame(0...24_000), on: ["t1"])
                        done["paste", default: 0] += 1
                    case 3:
                        try session.splitClips(at: [frame(0...22_000)], on: ["t1"])
                        done["split", default: 0] += 1
                    case 4:
                        guard let clip = anyClip() else { continue }
                        let other = session.tracks[0].clips.filter { _ in Bool.random(using: &random) }.map(\.id)
                        try session.nudge([clip.id] + other.filter { $0 != clip.id }, by: frame(-3_000...3_000))
                        done["nudge", default: 0] += 1
                    case 5:
                        guard let clip = anyClip() else { continue }
                        try session.move(clip.id, to: "t1", start: frame(0...22_000))
                        done["move", default: 0] += 1
                    case 6:
                        guard let clip = anyClip() else { continue }
                        let low = clip.start + frame(-1_000...1_000)
                        try session.trim(clip.id, to: low..<max(low, clip.end + frame(-1_000...1_000)))
                        done["trim", default: 0] += 1
                    case 7:
                        guard let clip = anyClip() else { continue }
                        try session.setFades([clip.id: Fades(fadeIn: frame(0...3_000), fadeOut: frame(0...3_000))!])
                        done["setFades", default: 0] += 1
                    case 9:
                        let start = frame(0...22_000)
                        try session.rippleDelete(start..<(start + frame(1...6_000)), on: ["t1"])
                        done["rippleDelete", default: 0] += 1
                    case 10:
                        try session.rippleInsert(frame(1...8_000), at: frame(0...24_000), on: ["t1"])
                        done["rippleInsert", default: 0] += 1
                    case 11:
                        guard let clip = anyClip() else { continue }
                        try session.setGain(Gain(dB: Bool.random(using: &random) ? 0 : -6)!, clip: clip.id)
                        done["setGain", default: 0] += 1
                    default:
                        var lengths: [ClipID: Frames] = [:]
                        let lane = session.tracks[0].clips
                        for index in lane.indices where Bool.random(using: &random) {
                            guard let limit = session.crossfadeLimit(after: index, in: lane) else { continue }
                            let (a, b) = (lane[index], lane[index + 1])
                            // A new crossfade at a seamless join with equal gains is refused (C32).
                            if lane.join(after: index) == .seamless, a.gain == b.gain, a.crossfades.end == .zero {
                                continue
                            }
                            lengths[lane[index].id] = Frames(
                                min(limit.count, Int.random(in: 0...2_000, using: &random)) / 2 * 2)
                        }
                        try session.setCrossfades(lengths)
                        done["setCrossfades", default: 0] += 1
                    }
                } catch {
                    #expect(session == before, "seed \(seed) step \(step): a refused edit changes nothing: \(error)")
                }
                do {
                    let data = try session.checkedData()
                    if session.fileVersion == 9, try Session(xml: data) != session {
                        Issue.record("seed \(seed) step \(step): a seamless crossfade does not read back")
                    }
                } catch {
                    Issue.record("seed \(seed) step \(step) kind \(kind): the session does not save: \(error)")
                    return
                }
                let check = Self.curveCheck(session.tracks[0].clips)
                (wrongCurves, seamless) = (wrongCurves + check.wrong, seamless + check.seamless)
            }
        }
        #expect(withCrossfade >= 1_000, "edits on a lane with a crossfade: \(withCrossfade)")
        #expect(wrongCurves == 0 && seamless >= 100, "\(wrongCurves) wrong curves, \(seamless) seamless crossfades")
        #expect(done.keys.count == 12, "each kind of edit ran: \(done)")
    }
}
