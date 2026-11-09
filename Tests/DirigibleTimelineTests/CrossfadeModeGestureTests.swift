import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// C42 window part: a move drag in Crossfade mode previews and commits `move(mode: .crossfade)`.
/// Fixture X: c at 0 ..< 96000 (offset 96000 of f) on t1, and d (offset 96000 of g) at 192000.
struct CrossfadeModeGestureTests {
    /// Control: the Overwrite move gives no crossfade at the join.
    @Test func aMoveDragPreviewsTheCrossfade() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
        try session.addFile(AudioFile(id: "g", path: "g.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.place(Clip(id: "c", file: "f", start: 0, offset: 96_000, length: 96_000), on: "t1")
        try session.place(Clip(id: "d", file: "g", start: 192_000, offset: 96_000, length: 48_000), on: "t1")
        var expected = session
        try expected.move("d", to: "t1", start: 72_000, mode: .crossfade)
        let crossfade = expected.clip("d")?.clip.crossfades.start
        #expect(crossfade == 24_000, "the Core value of C42")
        var g = ModeGesture(session, .crossfade)
        g.down(216_000)
        _ = g.drag(96_000)
        ModeGesture.expectSame(g.drawn, expected)
        let result = try #require(g.committed(g.up(96_000)))
        ModeGesture.expectSame(result.session, expected)
        let ripple = result.commit.ripple
        #expect(ripple == false)
    }
}
