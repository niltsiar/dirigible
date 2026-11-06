import Foundation
import Testing

@testable import DirigibleCore

/// Close Gaps (run timeline-edits, F81). Mono tracks "a" and "b" on file "f" of 480 000 frames, 48 kHz.
/// Track "a" has a 0 ..< 48 000, u 96 000 ..< 144 000, b 240 000 ..< 288 000, and c 384 000 ..< 432 000.
/// Track "b" has d 240 000 ..< 288 000. A marker "m" is at 300 000.
struct CloseGapsTests {
    var session: Session

    init() throws {
        session = try editFixture()
        for (id, start, length) in [
            ("a", 0, 48_000), ("u", 96_000, 48_000), ("b", 240_000, 48_000), ("c", 384_000, 48_000),
        ] {
            try session.place(
                Clip(id: ClipID(id), file: "f", start: Frames(start), offset: Frames(start), length: Frames(length)),
                on: "a")
        }
        try session.place(Clip(id: "d", file: "f", start: 240_000, offset: 240_000, length: 48_000), on: "b")
        try session.setMarker(Marker(id: "m", name: "m", position: 300_000, kind: .marker))
    }

    func starts(_ track: TrackID) -> [Frames] { session.track(track)?.clips.map(\.start) ?? [] }

    /// C1: the first test. Each later selected clip goes to the end of the clip before it in the lane.
    @Test mutating func eachLaterSelectedClipMovesToTheClipBeforeIt() throws {
        let moved = try session.closeGaps(["a", "b", "c"])
        #expect(starts("a") == [0, 96_000, 144_000, 192_000], "b goes to the end of u, c to the end of b")
        #expect(moved == ["b", "c"], "the result names the moved clips, in lane order")

        var later = try CloseGapsTests()
        try later.session.closeGaps(["b", "c"])
        #expect(later.starts("a") == [0, 96_000, 240_000, 288_000], "the first selected clip stays")
    }

    @Test mutating func closeGapsMovesNothingElse() throws {
        let gain = try #require(Gain(dB: 3))
        try session.setGains(["b": gain])
        try session.setFades(["b": try #require(Fades(fadeIn: 100, fadeOut: 200))])
        try session.setEnvelope([250_000: try #require(Gain(dB: -6))], clip: "b")
        let before = session
        let b = before.clip("b")!.clip
        try session.closeGaps(["a", "b", "c", "d"])
        var expected = b
        expected.start = 144_000
        #expect(session.clip("b")?.clip == expected, "the moved clip keeps its ID, gain, fades, and envelope")
        #expect(session.clip("u")?.clip == before.clip("u")?.clip, "an unselected clip stays")
        #expect(
            session.track("b")?.clips.map { $0 } == before.track("b")?.clips.map { $0 },
            "d is the first selected clip of its track")
        #expect(session.markers == before.markers, "a marker stays")
    }

    @Test mutating func eachTrackKeepsItsOwnFirstClip() throws {
        try session.place(Clip(id: "e", file: "f", start: 400_000, offset: 400_000, length: 8_000), on: "b")
        try session.closeGaps(["b", "c", "d", "e"])
        #expect(starts("a") == [0, 96_000, 240_000, 288_000], "b is the first selected clip of track a; c follows it")
        #expect(starts("b") == [240_000, 288_000], "e follows d")
    }

    @Test mutating func aTouchingClipKeepsItsCrossfade() throws {
        try session.place(Clip(id: "x", file: "f", start: 144_000, offset: 5_000, length: 48_000), on: "a")
        try session.setCrossfades(["u": 960])
        #expect(session.clip("u")?.clip.crossfades.end == 960, "control: the join has a crossfade")
        let before = session.clip("x")!.clip
        try session.closeGaps(["u", "x", "b"])
        #expect(session.clip("x")?.clip == before, "x touches u, so it stays with its crossfade")
        #expect(session.clip("u")?.clip.crossfades.end == 960)
        #expect(session.clip("b")?.clip.start == 192_000, "b moves to the end of x")
    }

    @Test mutating func aMovedClipDropsTheCrossfadeOfItsOldJoin() throws {
        try session.place(Clip(id: "n", file: "f", start: 288_000, offset: 5_000, length: 48_000), on: "a")
        try session.setCrossfades(["b": 960])
        #expect(session.clip("n")?.clip.crossfades.start == 960, "control: b and n have a crossfade")
        var together = session
        try together.closeGaps(["a", "b", "n"])
        #expect(together.clip("b")?.clip.crossfades.end == 960, "a pair that moves together keeps its join")
        #expect(together.clip("n")?.clip.start == 192_000)

        try session.closeGaps(["a", "b"])
        #expect(session.clip("b")?.clip.start == 144_000)
        #expect(session.clip("b")?.clip.crossfades == .zero, "b left its join")
        #expect(session.clip("n")?.clip.crossfades == .zero, "n lost the partner crossfade too")
        #expect(throws: Never.self, "the lane holds its pairing") {
            try ClipLane(validating: session.track("a")!.clips.map { $0 })
        }
    }

    @Test mutating func anUnknownClipChangesNothing() throws {
        let before = session
        #expect(throws: SessionError.unknownClip("nobody")) { try session.closeGaps(["a", "b", "nobody"]) }
        #expect(session == before)
        try session.closeGaps(["u"])
        #expect(session == before, "one selected clip has no clip to follow, so nothing changes")
    }
}
