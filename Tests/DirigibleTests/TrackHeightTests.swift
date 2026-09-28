import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Testing

@testable import DirigibleApp

/// Timeline-navigation criterion N14: Taller Tracks (Command-Down Arrow), Shorter Tracks
/// (Command-Up Arrow), and Fit Tracks to Window. 8 tracks, so the automatic height is under 120 pt;
/// the clip file is on disk, so no missing-media banner takes height after the open.
@Suite(.serialized) @MainActor struct TrackHeightTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func open(tracks: Int = 8) async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let lanes = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: tracks, seconds: 20, audio: true))
        lanes.3.viewWillMove(toWindow: nil)
        return lanes
    }

    func height(_ view: TimelineScrollView, _ window: NSWindow, is expected: Double) async -> Double {
        await until(limit: .seconds(10), "the lanes take \(expected) pt") {
            window.contentView?.layoutSubtreeIfNeeded()
            return view.lanes.inputs?.laneHeight == expected
        }
        return view.lanes.inputs?.laneHeight ?? 0
    }

    @Test func theKeysStepTheHeightAndFitGoesBack() async throws {
        let (model, _, window, view) = try await open()
        #expect(model.timeline.laneHeight == .automatic, "a new window is automatic")
        let start = try #require(view.lanes.inputs?.laneHeight)
        try #require(start < 120, "the automatic height \(start)")
        let taller = try #require(LaneHeight.steps.first { $0 > start })
        model.run(.tallerTracks)
        #expect(await height(view, window, is: taller) == taller)
        #expect(view.headers.host.frame.height == view.lanes.frame.height, "the header rows take the height")
        #expect(Double(view.lanes.frame.height) == 8 * taller)
        model.run(.shorterTracks)
        let shorter = try #require(LaneHeight.steps.last { $0 < taller })
        #expect(await height(view, window, is: shorter) == shorter)
        model.run(.fitTracks)
        #expect(model.timeline.laneHeight == .automatic)
        #expect(await height(view, window, is: start) == start)
        await model.close()
    }

    /// The lane at the top of the view stays at the top across a height step. 20 tracks, so the
    /// lanes are taller than the view at both heights.
    @Test func theTopLaneStaysAtTheTop() async throws {
        let (model, _, window, view) = try await open(tracks: 20)
        model.timeline.laneHeight = .fixed(160)
        _ = await height(view, window, is: 160)
        view.contentView.scroll(
            to: NSPoint(x: view.contentView.bounds.minX, y: 3 * 160 - view.contentView.contentInsets.top))
        view.reflectScrolledClipView(view.contentView)
        try #require(abs(view.shown.minY - 480) <= 0.5, "lane 3 is at the top: \(view.shown.minY)")
        model.run(.shorterTracks)
        _ = await height(view, window, is: 120)
        #expect(abs(view.shown.minY - 360) <= 0.5, "the top lane stays at the top: \(view.shown.minY)")
        await model.close()
    }

    /// With a focused name field, Command-Down and Command-Up go to the field first (0018 E4).
    @Test func commandDownGoesToAFocusedField() async throws {
        let (model, _, window, view) = try await open()
        let start = view.lanes.inputs?.laneHeight
        let editor = try await focusName(in: window)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let down = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .function, .numericPad], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)!
        app.timeline(.tallerTracks, event: down, in: window)
        #expect(editor.selectedRange().location == editor.string.count, "Command-Down goes to the focused field")
        #expect(model.timeline.laneHeight == .automatic && view.lanes.inputs?.laneHeight == start)
        await model.close()
    }
}
