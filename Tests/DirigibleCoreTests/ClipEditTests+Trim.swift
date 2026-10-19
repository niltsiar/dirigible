import Foundation
import Testing

@testable import DirigibleCore

/// A trim to a range that passes a neighbor puts the clip at its sorted place. Clips a, b, and c
/// are 10 000 frames long at 0, 20 000, and 40 000 (offset equal to start) on "t1".
extension ClipEditTests {
    mutating func placeABC() throws {
        for (id, start) in [("a", 0), ("b", 20_000), ("c", 40_000)] as [(ClipID, Frames)] {
            try session.place(clip(id, start: start, offset: start, length: 10_000), on: "t1")
        }
    }

    @Test mutating func trimPastTheNextClipsMovesTheClipToItsSortedPlace() throws {
        try placeABC()
        let before = session
        try session.trim("a", to: 31_000..<35_000)
        #expect(lane("t1").map(\.id) == ["b", "a", "c"], "past one clip")
        #expect(session.track("t1")?.clips.index(holding: 33_000) == 1)

        session = before
        try session.trim("a", to: 60_000..<65_000)
        #expect(lane("t1").map(\.id) == ["b", "c", "a"], "past two clips")
        #expect(lane("t1").last == clip("a", start: 60_000, offset: 60_000, length: 5_000))
        #expect(session.track("t1")?.clips.index(holding: 62_000) == 2)

        session = before
        #expect(throws: SessionError.overlap("a", "b")) { try session.trim("a", to: 5_000..<45_000) }
        #expect(session == before, "a range over two clips is refused")
    }

    @Test mutating func trimBeforeThePreviousClipMovesTheClip() throws {
        try placeABC()
        let before = session
        try session.trim("c", to: 11_000..<15_000)
        #expect(lane("t1").map(\.id) == ["a", "c", "b"])
        #expect(session.track("t1")?.clips.index(holding: 12_000) == 1)

        session = before
        #expect(throws: SessionError.overlap("c", "a")) { try session.trim("c", to: 1_000..<5_000) }
        #expect(session == before, "a range inside a is refused")
    }

    @Test mutating func aTrimThatTouchesItsNeighborsStaysInPlace() throws {
        try placeABC()
        let before = session
        try session.trim("b", to: 10_000..<15_000)
        #expect(lane("t1").map(\.id) == ["a", "b", "c"], "start at the end of a")
        session = before
        try session.trim("b", to: 35_000..<40_000)
        #expect(lane("t1").map(\.id) == ["a", "b", "c"], "end at the start of c")
        session = before
        try session.trim("b", to: 50_000..<55_000)
        #expect(lane("t1").map(\.id) == ["a", "c", "b"], "start at the end of c passes it")
        session = before
        #expect(throws: SessionError.overlap("b", "a")) { try session.trim("b", to: 9_999..<15_000) }
        #expect(session == before, "one frame into a is an overlap")
    }

    /// A and B touch at 20 000 with a crossfade of 960 frames. A cut join: B plays from offset 50 000.
    private mutating func placeCrossfadedAB() throws {
        try session.place(clip("A", start: 10_000, offset: 10_000, length: 10_000), on: "t1")
        try session.place(clip("B", start: 20_000, offset: 50_000, length: 10_000), on: "t1")
        try session.place(clip("C", start: 40_000, offset: 40_000, length: 10_000), on: "t1")
        try session.setCrossfades(["A": 960])
    }

    @Test mutating func aTrimBetweenItsNeighborsKeepsItsCrossfade() throws {
        try placeCrossfadedAB()
        try session.trim("B", to: 20_000..<28_000)
        #expect(session.clip("A")?.clip.crossfades.end.count == 960)
        #expect(session.clip("B")?.clip.crossfades.start.count == 960)
    }

    @Test mutating func aClipThatPassesANeighborLosesItsCrossfade() throws {
        try placeCrossfadedAB()
        try session.trim("B", to: 60_000..<65_000)
        #expect(lane("t1").map(\.id) == ["A", "C", "B"])
        #expect(lane("t1").allSatisfy { $0.crossfades == .zero })
        #expect(throws: Never.self) { try session.checkedData() }
    }

    /// Six clips of 5 000 frames at 15 000 steps on a file of 100 000 frames. Each trim takes any
    /// range in the file. After it, the lane is sorted with no overlap, `index(holding:)` finds each
    /// clip, and the session reads back equal. A refused trim is an overlap and changes nothing.
    @Test mutating func randomTrimsKeepTheLaneSorted() throws {
        let start = session
        var (moved, refused) = (0, 0)
        for seed in 1...200 {
            var random = SplitMix(seed: UInt64(seed))
            session = start
            for index in 0..<6 {
                let at = Frames(index * 15_000)
                try session.place(clip(ClipID("c\(index)"), start: at, offset: at, length: 5_000), on: "t1")
            }
            for step in 0..<20 {
                let before = session
                let ids = lane("t1").map(\.id)
                let id = try #require(ids.randomElement(using: &random))
                let low = Int.random(in: 0...99_000, using: &random)
                let range = Frames(low)..<Frames(min(100_000, low + Int.random(in: 1...20_000, using: &random)))
                do {
                    try session.trim(id, to: range)
                    moved += lane("t1").map(\.id) == ids ? 0 : 1
                } catch {
                    refused += 1
                    if case SessionError.overlap = error {} else { Issue.record("seed \(seed) step \(step): \(error)") }
                    #expect(session == before, "seed \(seed) step \(step): a refused trim changes nothing")
                }
                let clips = lane("t1")
                #expect(
                    zip(clips, clips.dropFirst()).allSatisfy { $0.end <= $1.start },
                    "seed \(seed) step \(step): the lane is sorted with no overlap")
                let lookup = session.track("t1")
                #expect(
                    clips.indices.allSatisfy { lookup?.clips.index(holding: clips[$0].start) == $0 },
                    "seed \(seed) step \(step): index(holding:) finds each clip")
                #expect(
                    try Session(xml: session.checkedData()) == session,
                    "seed \(seed) step \(step): the session reads back")
            }
        }
        #expect(moved >= 200 && refused >= 200, "trims that passed a neighbor: \(moved), refused: \(refused)")
    }
}
