import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// One drag has one mode: the mode of the press, whatever the context says at a later event.
struct DragModePressTests {
    /// The one commit of a drag on fixture N that presses on b in `press`, and sets the context mode
    /// to `later` after the first event.
    static func moveDrag(press: DragMode, later: DragMode?) throws -> (commit: GestureCommit, session: Session) {
        var g = ModeGesture(try NoOverlapGestureTests.fixtureN(), press)
        g.down(120_000)
        _ = g.drag(170_000 + 24_000)
        if let later { g.mode = later }
        _ = g.drag(216_000 + 24_000)
        return try #require(g.committed(g.up(216_000 + 24_000)))
    }

    @Test(arguments: [
        (DragMode.noOverlap, DragMode.overwrite), (.overwrite, .noOverlap), (.shuffle, .overwrite),
        (.overwrite, .shuffle), (.crossfade, .noOverlap),
    ])
    func aMoveDragKeepsTheModeOfItsPress(press: DragMode, later: DragMode) throws {
        let kept = try Self.moveDrag(press: press, later: nil)
        let changed = try Self.moveDrag(press: press, later: later)
        ModeGesture.expectSame(changed.session, kept.session)
        #expect(changed.commit.ripple == kept.commit.ripple)
    }

    @Test(arguments: [(DragMode.noOverlap, DragMode.overwrite), (.overwrite, .noOverlap)])
    func aGroupDragKeepsTheModeOfItsPress(press: DragMode, later: DragMode) throws {
        func run(_ later: DragMode?) throws -> Session {
            var g = ModeGesture(try NoOverlapGestureTests.fixtureN(), press)
            g.selection = .clips(try #require(ClipSet(["a", "b"])))
            g.down(120_000)
            _ = g.drag(120_000 + 48_000)
            if let later { g.mode = later }
            _ = g.drag(120_000 + 48_001)
            return try #require(g.committed(g.up(120_000 + 48_001))).session
        }
        ModeGesture.expectSame(try run(later), try run(nil))
    }
}
