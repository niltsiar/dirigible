import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The Shift-Command roll and slip drags in a real session window (decision 0020, criteria C20 and
/// C22). The lanes are 512 frames per point and 100 pt lanes (`standaloneLanes`): c1 of t1 is split
/// at x 900 into a left and a right clip, and c1 of t2 is whole.
@Suite(.serialized) @MainActor struct RollSlipMouseTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    static let flags: NSEvent.ModifierFlags = [.shift, .command]

    init() throws { folder = try TemporaryFolder() }

    /// The window with the split session, the id of the left clip, and the session before the roll.
    func joined() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView, ClipID) {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        try studio.edit(ripple: false) { s throws(SessionError) in _ = try s.splitClips(at: [460_800], on: ["t1"]) }
        let (window, view) = standaloneLanes(model, studio)
        return (model, studio, window, view, try #require(studio.session.tracks[0].clips.first).id)
    }

    func send(_ type: NSEvent.EventType, _ x: Double, _ y: Double, _ view: TimelineScrollView) throws {
        let event = try mouse(type, NSPoint(x: x, y: y), in: view, flags: type == .leftMouseDown ? Self.flags : [])
        switch type {
        case .leftMouseDown: view.lanes.mouseDown(with: event)
        case .leftMouseDragged: view.lanes.mouseDragged(with: event)
        default: view.lanes.mouseUp(with: event)
        }
    }

    /// C20: during the drag the lanes draw the roll and the Studio keeps the session; the mouse-up
    /// makes one undo entry, and one Undo gives the session before.
    @Test func aRollDragIsOneUndoEntry() async throws {
        let (model, studio, window, view, left) = try await joined()
        let before = studio.session
        try send(.leftMouseDown, 898, 10, view)
        try send(.leftMouseDragged, 948, 10, view)
        drawNow(window)
        #expect(view.lanes.inputs?.session.clip(left)?.clip.length == 486_400, "the preview")
        #expect(studio.session == before, "the Studio keeps the session during the drag")
        try send(.leftMouseUp, 948, 10, view)
        #expect(studio.session.clip(left)?.clip.length == 486_400)
        model.undo()
        #expect(studio.session == before, "one Undo gives the session before")
        window.close()
        await model.close()
    }

    /// C20 (performance-criteria.md, the state after a commit): a second Shift-Command drag after
    /// the commit draws its own preview, once per event.
    @Test func aSecondRollAfterACommitDrawsItsPreview() async throws {
        let (model, studio, window, view, left) = try await joined()
        try send(.leftMouseDown, 898, 10, view)
        try send(.leftMouseDragged, 948, 10, view)
        try send(.leftMouseUp, 948, 10, view)
        drawNow(window)
        let draws = view.lanes.draws

        try send(.leftMouseDown, 948, 10, view)
        try send(.leftMouseDragged, 998, 10, view)
        drawNow(window)

        #expect(view.lanes.draws == draws + 1)
        #expect(view.lanes.inputs?.session.clip(left)?.clip.length == 512_000, "the second preview")
        #expect(view.lanes.drawnRect.width > 0)
        try send(.leftMouseUp, 998, 10, view)
        #expect(studio.session.clip(left)?.clip.length == 512_000)
        window.close()
        await model.close()
    }

    /// C22: a slip drag is one undo entry, and the box stays.
    @Test func aSlipDragIsOneUndoEntry() async throws {
        let (model, studio, window, view, left) = try await joined()
        let before = studio.session
        let clip = try #require(before.clip(left)?.clip)
        // The left clip is at offset 0: its content slips to the left only (a drag to the left).
        try send(.leftMouseDown, 500, 30, view)
        try send(.leftMouseDragged, 450, 30, view)
        drawNow(window)
        try send(.leftMouseUp, 450, 30, view)
        #expect(studio.session.clip(left)?.clip.offset == clip.offset + 25_600)
        #expect(studio.session.clip(left)?.clip.range == clip.range, "the box stays")
        model.undo()
        #expect(studio.session == before)
        window.close()
        await model.close()
    }
}
