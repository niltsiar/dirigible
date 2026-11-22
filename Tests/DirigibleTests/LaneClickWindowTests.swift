import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// A click in an empty part of a lane selects its track (F109, decision 0017), in a real session
/// window. Tracks t1 to t4 hold one clip each (c1 to c4) from 0, at 480 frames per point and 60 pt
/// lanes: x 200 pt is frame 96,000, and lane n is y 60 n to 60 n + 60. The window applies a seek in
/// a task, so a test that reads the playhead waits for it.
@Suite(.serialized) @MainActor struct LaneClickWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func open(seconds: Int = 1, audio: Bool = false) async throws -> (SessionWindow, Studio, TimelineScrollView) {
        let package = try await timelinePackage(in: folder.url, tracks: 4, seconds: seconds, audio: audio)
        let (model, studio, _, view) = try await openLanes(app, package)
        await until("the first view is fitted") { view.fitted }
        model.timeline.scale = TimelineScale(framesPerPoint: 480)
        model.timeline.laneHeight = .fixed(60)
        await until("the lanes take the zoom and the height") {
            view.framesPerPoint == 480 && view.lanes.inputs?.laneHeight == 60
        }
        view.scroll(toFrame: 0)
        return (model, studio, view)
    }

    /// A click at the lane point (`x`, `y`).
    func click(_ view: TimelineScrollView, _ x: Double, _ y: Double, flags: NSEvent.ModifierFlags = []) throws {
        let point = NSPoint(x: x, y: y)
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, point, in: view, flags: flags))
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, point, in: view, flags: flags))
    }

    /// Command-clicks c1 and c2, then Copy: the clip set of two clips on t1 and t2 is on the clipboard.
    func copyTwoClips(_ model: SessionWindow, _ view: TimelineScrollView) throws {
        try click(view, 20, 10, flags: .command)
        try click(view, 20, 70, flags: .command)
        try #require(model.timeline.selection == ClipSet(["c1", "c2"]).map { .clips($0) }, "the clip set")
        model.run(.copy)
    }

    /// K10: Paste of a clip set goes to the clicked track and the track under it, not to the source tracks.
    @Test func aPasteOfAClipSetGoesToTheClickedTrack() async throws {
        let (model, studio, view) = try await open()
        try copyTwoClips(model, view)

        try click(view, 200, 130)
        await until("the playhead goes to the click") { studio.playhead == 96_000 }
        model.run(.paste)
        await until("the paste ends") { model.importJob == nil }

        #expect(studio.session.track("t3")?.clips.map(\.start) == [0, 96_000], "t3: its clip and the copy of c1")
        #expect(studio.session.track("t4")?.clips.map(\.start) == [0, 96_000], "t4: its clip and the copy of c2")
        #expect(studio.session.track("t1")?.clips.count == 1 && studio.session.track("t2")?.clips.count == 1)
        await model.close()
    }

    /// K11: a click on the last track leaves one track under it for two clips, so Paste adds a new
    /// last track, named after the lane of c2, for the copy of c2 (C9).
    @Test func aPasteOfAClipSetPastTheLastTrackAddsATrack() async throws {
        let (model, studio, view) = try await open()
        try copyTwoClips(model, view)
        try click(view, 200, 190)
        await until("the playhead goes to the click") { studio.playhead == 96_000 }
        let before = studio.session

        model.run(.paste)

        #expect(model.alert == nil, "\(String(describing: model.alert))")
        let added = try #require(studio.session.tracks.last)
        #expect(studio.session.tracks.map(\.id) == before.tracks.map(\.id) + [added.id])
        #expect(studio.session.track("t4")?.clips.map(\.start) == [0, 96_000], "t4: its clip and the copy of c1")
        #expect(added.name == before.track("t2")?.name && added.clips.map(\.start) == [96_000])
        await model.close()
    }

    /// K12: during play, the click selects the track and moves the playhead; play goes on.
    @Test func aLaneClickDuringPlaySelectsAndSeeks() async throws {
        let (model, studio, view) = try await open(seconds: 20)
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        try #require(studio.playback != .stopped, "the play runs")

        try click(view, 200, 110)

        await until("the playhead goes to the click") { studio.playhead >= 96_000 }
        #expect(model.timeline.selection == .range(Marks(tracks: ["t2"])))
        #expect(studio.playback != .stopped, "play goes on")
        await studio.perform(.playStop)
        await model.close()
    }

    /// K13: during a take, the click selects the track and the playhead stays. Control: with no
    /// take, the same click and the same wait move the playhead.
    @Test func aLaneClickDuringATakeSelectsItsTrackOnly() async throws {
        let (model, studio, view) = try await open()
        try click(view, 200, 70)
        await Task { @MainActor in }.value
        #expect(studio.playhead == 96_000, "control: no take")

        studio.transport = .recording(take: 1)
        let during = studio.playhead
        try click(view, 200, 130)
        await Task { @MainActor in }.value

        #expect(model.timeline.selection == .range(Marks(tracks: ["t3"])), "the track")
        #expect(studio.playhead == during, "the take keeps the playhead")
        studio.transport = .idle
        await model.close()
    }

    /// K14: Split after a click in the lower third of a clip of t2 cuts t2 only.
    @Test func aSplitAfterALaneClickCutsOnlyThatTrack() async throws {
        let (model, studio, view) = try await open(seconds: 4)

        try click(view, 200, 110)
        await until("the playhead goes to the click") { studio.playhead == 96_000 }
        model.run(.split)

        #expect(studio.session.track("t2")?.clips.map(\.start) == [0, 96_000], "t2 is cut")
        #expect(studio.session.track("t1")?.clips.count == 1, "t1 is not cut")
        await model.close()
    }

    /// K16: Import after a click goes to the clicked track at the click.
    @Test func anImportAfterALaneClickGoesToItsTrack() async throws {
        let (model, studio, view) = try await open()

        try click(view, 200, 70)
        await until("the playhead goes to the click") { studio.playhead == 96_000 }

        let target = importTarget(model.timeline.selection, in: studio.session, playhead: studio.playhead)
        #expect(target.track == "t2" && target.start == 96_000)
        await model.close()
    }

    /// K17: the track of the click shows as selected, as after a click on its header.
    @Test func aLaneClickShowsItsTrackSelected() async throws {
        let (model, _, view) = try await open()

        try click(view, 200, 70)

        await until("the lanes take the selection") { view.lanes.inputs.map(LaneShade.selected) == [1] }
        #expect(model.timeline.selection.headerTracks(in: try #require(model.studio).session) == ["t2"])
        await model.close()
    }

    /// K20 through the hit test: under the last lane, one click keeps the track of a lane click,
    /// and a double-click clears the selection. The events go to the hit view of the frame view, as
    /// `NSWindow.sendEvent` sends them in a key window.
    @Test func aDoubleClickBelowTheLastLaneClearsTheSelection() async throws {
        let (model, _, view) = try await open()
        let window = try #require(view.window)
        try click(view, 200, 70)
        try #require(model.timeline.selection == .range(Marks(tracks: ["t2"])), "the lane click selects t2")
        let below = NSPoint(x: 200, y: 270)
        try #require(view.shown.maxY > below.y, "the view shows y \(below.y) under the 4 lanes")
        drawNow(window)
        let hit = try #require(window.contentView?.superview?.hitTest(view.lanes.convert(below, to: nil)))
        try #require(hit.isDescendant(of: view.contentView), "the point is in the timeline area, not in \(hit)")

        hit.mouseDown(with: try mouse(.leftMouseDown, below, in: view))
        hit.mouseUp(with: try mouse(.leftMouseUp, below, in: view))
        #expect(model.timeline.selection == .range(Marks(tracks: ["t2"])), "one click keeps the track")
        hit.mouseDown(with: try mouse(.leftMouseDown, below, in: view, clicks: 2))
        hit.mouseUp(with: try mouse(.leftMouseUp, below, in: view, clicks: 2))

        #expect(model.timeline.selection == .none, "the double-click clears the selection")
        #expect(view.lanes.shownCursor == .arrow, "no tracking area under the lanes resets an I-beam")
        await model.close()
    }

    /// K21: Remove Track after a click asks first, and removes the track only after the confirmation.
    @Test func aRemoveTrackAfterALaneClickAsksFirst() async throws {
        let (model, studio, view) = try await open()

        try click(view, 200, 70)
        model.run(.removeTrack)

        #expect(model.alert == .confirmRemoveTracks(["t2"]))
        #expect(studio.session.tracks.map(\.id) == ["t1", "t2", "t3", "t4"], "the track stays")
        model.confirmRemoveTracks(["t2"])
        #expect(studio.session.tracks.map(\.id) == ["t1", "t3", "t4"])
        await model.close()
    }

    /// After a lane click the selection has no points, so each ripple item beeps and changes
    /// nothing, and the track stays selected. Control: with an in point and an out point, Cut in
    /// Selected Tracks cuts with no beep.
    @Test func aRippleAfterALaneClickBeeps() async throws {
        let (model, studio, view) = try await open()
        var beeps = 0
        model.beep = { beeps += 1 }
        try click(view, 200, 70)
        try #require(model.timeline.selection == .range(Marks(tracks: ["t2"])), "the lane click selects t2")
        let before = studio.session
        let commands: [TimelineCommand] = [.cut, .deleteCloseGap, .cutSelectedTracks, .deleteCloseGapSelectedTracks]

        for command in commands { model.run(command) }

        #expect(beeps == commands.count && studio.session == before && model.clipboard == nil, "beeps \(beeps)")
        #expect(model.timeline.selection == .range(Marks(tracks: ["t2"])), "the track stays selected")
        model.timeline.selection = .range(Marks(inPoint: 0, outPoint: 24_000, tracks: ["t2"]))
        model.run(.cutSelectedTracks)
        #expect(beeps == commands.count && studio.session != before, "the control cuts")
        await model.close()
    }

    /// Only the area under the last lane, inside the width of the lanes, goes to the lanes. The gap
    /// of an elastic overscroll above lane 0 and left of x 0 stays with the clip view. A clip view
    /// clamps a bounds change outside a scroll gesture, so the test clip view keeps the overscroll.
    /// Control: a point under the last lane goes to the lanes.
    @Test func onlyThePointsUnderTheLastLaneGoToTheLanes() async throws {
        let (model, _, view) = try await open()
        let window = try #require(view.window)
        func hit(_ x: Double, _ y: Double) -> NSView? {
            window.contentView?.superview?.hitTest(view.lanes.convert(NSPoint(x: x, y: y), to: nil))
        }
        let clip = OverscrollClipView(frame: view.contentView.frame)
        (clip.automaticallyAdjustsContentInsets, clip.contentInsets) = (false, view.contentView.contentInsets)
        let (lanes, origin) = (view.lanes, view.contentView.bounds.origin)
        view.contentView = clip
        clip.documentView = lanes
        clip.setBoundsOrigin(origin)
        #expect(hit(200, 270) === view.lanes, "under the last lane")

        clip.setBoundsOrigin(NSPoint(x: origin.x - 40, y: origin.y - 40))
        try #require(view.shown.minX == -40 && view.shown.minY == -40, "the overscroll shows \(view.shown)")

        #expect(hit(200, -10) === clip, "above lane 0")
        #expect(hit(-10, 100) === clip, "left of x 0")
        await model.close()
    }
}

/// A clip view that keeps any bounds, as during the elastic overscroll of a scroll gesture.
private final class OverscrollClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
}
