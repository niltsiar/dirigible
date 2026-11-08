import Foundation
import Testing

@testable import DirigibleCore

/// The overlap modes of a move (decision 0020) on fixture N. Track `t1` has a 0 ..< 48 000, b
/// 96 000 ..< 144 000, and c 192 000 ..< 240 000. Track `t2` has a2 0 ..< 48 000 and c2
/// 192 000 ..< 240 000. Each clip is of file f, at the offset of its start.
struct DragModeTests {
    var session: Session

    init() throws {
        session = try Self.overlapFixture()
    }

    static func overlapFixture() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack("t2", name: "T2", layout: .mono)
        let clips: [(ClipID, TrackID, Int)] = [
            ("a", "t1", 0), ("b", "t1", 96_000), ("c", "t1", 192_000), ("a2", "t2", 0), ("c2", "t2", 192_000),
        ]
        for (id, track, start) in clips {
            try session.place(
                Clip(id: id, file: "f", start: Frames(start), offset: Frames(start), length: 48_000), on: track)
        }
        return session
    }

    func lane(_ track: TrackID, in session: Session? = nil) -> [Clip] {
        (session ?? self.session).track(track).map { Array($0.clips) } ?? []
    }

    /// C40: `.overwrite` is the move of today, also at a cover (c is trimmed to start at 218 000).
    @Test mutating func overwriteIsTheMoveOfToday() throws {
        var plain = session
        try plain.move("b", to: "t1", start: 170_000)
        try session.move("b", to: "t1", start: 170_000, mode: .overwrite)
        #expect(session == plain)
        #expect(lane("t1").last == Clip(id: "c", file: "f", start: 218_000, offset: 218_000, length: 22_000))

        var nudged = try Self.overlapFixture()
        var plainNudge = nudged
        try plainNudge.nudge(["b"], by: 74_000)
        try nudged.nudge(["b"], by: 74_000, mode: .overwrite)
        #expect(nudged == plainNudge)
        #expect(nudged != (try Self.overlapFixture()), "the nudge reaches the output")
    }

    /// C41: a start one frame past the touch covers c and throws; the touch passes.
    @Test mutating func noOverlapRefusesACoveredClip() throws {
        let before = session
        #expect(throws: SessionError.overlap("b", "c")) {
            try session.move("b", to: "t1", start: 144_001, mode: .noOverlap)
        }
        #expect(session == before)
        #expect(throws: SessionError.overlap("b", "c")) { try session.nudge(["b"], by: 48_001, mode: .noOverlap) }
        #expect(session == before)

        var touching = session
        try touching.move("b", to: "t1", start: 144_000, mode: .noOverlap)
        #expect(lane("t1", in: touching).map(\.start) == [0, 144_000, 192_000], "b touches c and cuts nothing")
        try session.nudge(["b"], by: 48_000, mode: .noOverlap)
        #expect(session == touching)
    }

    /// C41, U55: the free starts of b. Each end passes `.noOverlap` and one frame past it covers a clip.
    @Test mutating func eachFreeSpanEndPassesNoOverlap() throws {
        let own = try session.freeSpan(of: "b", on: "t1", near: 96_000)
        #expect(own == 48_000...144_000)
        #expect(
            try session.freeSpan(of: "b", on: "t1", near: 170_000) == 48_000...144_000,
            "a covered start takes the nearest")
        for start in [own.lowerBound, own.upperBound] {
            var moved = session
            try moved.move("b", to: "t1", start: start, mode: .noOverlap)
        }
        for start in [own.lowerBound - 1, own.upperBound + 1] {
            #expect(throws: SessionError.self, "\(start) covers a clip") {
                var moved = session
                try moved.move("b", to: "t1", start: start, mode: .noOverlap)
            }
        }

        let last = try session.freeSpan(of: "b", on: "t1", near: 260_000)
        #expect(last == 240_000...Frames.limit)
        var atLimit = session
        try atLimit.move("b", to: "t1", start: Frames.limit, mode: .noOverlap)
        #expect(throws: SessionError.frameOutOfRange) {
            var moved = session
            try moved.move("b", to: "t1", start: Frames.limit + 1, mode: .noOverlap)
        }

        #expect(
            try session.freeSpan(of: "b", on: "t2", near: 192_000) == 48_000...144_000, "a tie takes the earlier span")
        #expect(try session.freeSpan(of: "b", on: "t2", near: 260_000) == 240_000...Frames.limit)
        #expect(throws: SessionError.unknownClip("nobody")) { try session.freeSpan(of: "nobody", on: "t1", near: 0) }
        #expect(throws: SessionError.unknownTrack("nobody")) { try session.freeSpan(of: "b", on: "nobody", near: 0) }
    }
}

/// Crossfade mode on fixture X. Track `t1` has c 0 ..< 96 000 of file f at offset 96 000. The moved
/// clip d is on `t2`: it has length 48 000 and offset 96 000 of file g.
struct CrossfadeModeTests {
    static func fixture(offset: Frames = 96_000, file: FileID = "g") throws -> Session {
        var session = Session(sampleRate: 48_000)
        for id in ["f", "g"] as [FileID] {
            try session.addFile(AudioFile(id: id, path: "\(id).wav", layout: .mono, length: 480_000))
        }
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack("t2", name: "T2", layout: .mono)
        try session.place(Clip(id: "c", file: "f", start: 0, offset: 96_000, length: 96_000), on: "t1")
        try session.place(Clip(id: "d", file: file, start: 0, offset: offset, length: 48_000), on: "t2")
        return session
    }

    /// The lane `t1` after d moves to `start`: the ID, the start, the length, and the crossfade lengths.
    static func result(
        _ start: Frames, offset: Frames = 96_000, file: FileID = "g", nudge: Bool = false,
        mode: OverlapMode = .crossfade
    ) throws -> [String] {
        var session = try fixture(offset: offset, file: file)
        if nudge {
            try session.nudge(["d"], by: start, lanes: -1, mode: mode)
        } else {
            try session.move("d", to: "t1", start: start, mode: mode)
        }
        return session.track("t1")!.clips.map {
            "\($0.id) \($0.start.count) \($0.length.count) \($0.crossfades.start.count) \($0.crossfades.end.count)"
        }
    }

    /// C42: the covered length, rounded down to even and held by the handle limit.
    @Test func crossfadeModeCrossfadesTheCoveredLength() throws {
        #expect(try Self.result(72_000) == ["c 0 72000 0 24000", "d 72000 48000 24000 0"])
        #expect(try Self.result(71_999) == ["c 0 71999 0 24000", "d 71999 48000 24000 0"], "24 001 rounds down")
        #expect(try Self.result(96_000) == ["c 0 96000 0 0", "d 96000 48000 0 0"], "a touch covers nothing")
        #expect(try Self.result(95_999) == ["c 0 95999 0 0", "d 95999 48000 0 0"], "one frame rounds to none")
        #expect(
            try Self.result(72_000, offset: 4_000) == ["c 0 72000 0 8000", "d 72000 48000 8000 0"],
            "the handle before d limits the length")
        #expect(
            try Self.result(24_000) == [
                "c 0 24000 0 48000", "d 24000 48000 48000 48000", "c@72000 72000 24000 48000 0",
            ],
            "a drop inside c crossfades both joins")
        #expect(
            try Self.result(48_000, offset: 144_000, file: "f") == ["c 0 48000 0 0", "d 48000 48000 0 0"],
            "a join that can heal gets none")
        #expect(
            try Self.result(72_000, mode: .overwrite) == ["c 0 72000 0 0", "d 72000 48000 0 0"],
            "the control: overwrite gives no crossfade")
    }

    @Test func aNudgeInCrossfadeModeGivesTheSameRows() throws {
        #expect(try Self.result(72_000, nudge: true) == ["c 0 72000 0 24000", "d 72000 48000 24000 0"])
        #expect(
            try Self.result(24_000, nudge: true)
                == ["c 0 24000 0 48000", "d 24000 48000 48000 48000", "c@72000 72000 24000 48000 0"])
        #expect(try Self.result(72_000, nudge: true, mode: .overwrite) == ["c 0 72000 0 0", "d 72000 48000 0 0"])
    }
}
