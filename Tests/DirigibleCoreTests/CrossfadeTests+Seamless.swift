import Foundation
import Testing

@testable import DirigibleCore

/// A crossfade at a seamless join (decision 0036): B plays on in the file of A from the frame where
/// A stops, so B is on file "fa" at offset 5 000.
extension CrossfadeTests {
    mutating func seamlessJoin(gainB: Gain) throws {
        try join(b: { ($0.file, $0.offset, $0.gain) = ("fa", 5_000, gainB) })
    }

    var lane: ClipLane { session.tracks[0].clips }

    /// The clips of `lane` whose sounding curves are not the curves of their joins (C32), and the
    /// count of crossfades at a seamless join. A crossfade has a touching partner, so the file frames
    /// give the join kind.
    static func curveCheck(_ lane: ClipLane) -> (wrong: Int, seamless: Int) {
        var (wrong, seamless) = (0, 0)
        for index in lane.indices {
            let clip = lane[index]
            func curve(_ length: Frames, after left: Int) -> Fades.Curve {
                length != .zero && lane[left].isSeamless(with: lane[left + 1]) ? .linear : .sine
            }
            let expected = Fades.Curves(
                start: curve(clip.crossfades.start, after: index - 1), end: curve(clip.crossfades.end, after: index))
            if lane.sounding(at: index).curves != expected { wrong += 1 }
            if expected.end == .linear { seamless += 1 }
        }
        return (wrong, seamless)
    }

    /// C32 and C34: both halves at a seamless join with two gains get the linear curve, a butt join
    /// keeps the sine curve, and the session writes version 9 and reads back equal.
    @Test mutating func aCrossfadeAtASeamlessJoinUsesEqualGain() throws {
        try seamlessJoin(gainB: #require(Gain(dB: -6)))
        try session.setCrossfades(["A": 960])
        #expect(crossfades("A") == Crossfades(start: 0, end: 960) && crossfades("B") == Crossfades(start: 960, end: 0))
        #expect(lane.sounding(at: 0).curves == Fades.Curves(start: .sine, end: .linear), "A")
        #expect(lane.sounding(at: 1).curves == Fades.Curves(start: .linear, end: .sine), "B")
        #expect(session.fileVersion == 9)
        let data = try session.checkedData()
        #expect(String(decoding: data, as: UTF8.self).contains(#"version="9""#))
        #expect(try Session(xml: data) == session, "version 9 reads back equal")

        var butt = try CrossfadeTests()
        try butt.join(b: { $0.gain = Gain(dB: -6)! })
        try butt.session.setCrossfades(["A": 960])
        #expect(butt.lane.sounding(at: 0).curves == .sine && butt.lane.sounding(at: 1).curves == .sine)
        #expect(butt.session.fileVersion == 4, "a crossfade at a butt join keeps version 4")
    }

    /// C32: a new crossfade at a seamless join with equal gains changes no sample, so both forms of
    /// `setCrossfades` refuse it and change nothing. L = 0 there is not refused.
    @Test mutating func aCrossfadeAtASeamlessJoinWithEqualGainsIsRefused() throws {
        try seamlessJoin(gainB: .zero)
        let before = session
        #expect(throws: SessionError.crossfadeAtEqualGains("A")) { try session.setCrossfades(["A": 960]) }
        #expect(throws: SessionError.crossfadeAtEqualGains("A"), "the lane form") {
            try session.setCrossfades(lanes: [0: [(index: 0, length: 960)]])
        }
        #expect(session == before && session.fileVersion == 1, "a refused crossfade changes nothing")
        #expect(throws: Never.self, "L = 0") { try session.setCrossfades(["A": 0]) }
        #expect(session == before)
    }

    /// C32: a gain edit that makes the two gains equal keeps the crossfade and version 9; a kept
    /// crossfade there can change its length or go to 0.
    @Test mutating func aKeptCrossfadeAtEqualGainsCanChangeItsLength() throws {
        try seamlessJoin(gainB: #require(Gain(dB: -6)))
        try session.setCrossfades(["A": 960])
        try session.setGain(.zero, clip: "B")
        #expect(crossfades("B") == Crossfades(start: 960, end: 0), "the gain edit keeps the crossfade")
        #expect(session.fileVersion == 9)
        #expect(try Session(xml: session.checkedData()) == session, "a version 9 file with equal gains reads")
        try session.setCrossfades(["A": 2_000])
        #expect(
            crossfades("A") == Crossfades(start: 0, end: 2_000) && crossfades("B") == Crossfades(start: 2_000, end: 0))
        try session.setCrossfades(["A": 0])
        #expect(allCrossfades.isEmpty && session.fileVersion == 1, "L = 0 removes it")
    }
}
