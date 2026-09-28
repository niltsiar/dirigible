import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 1b criterion H10: the lanes take the dark palette in a dark window, at the first draw and
/// at an appearance change, with one full render per change. The tests set the appearance of their
/// own window, never `NSApp.appearance` (a shared resource of parallel suites).
@Suite(.serialized) @MainActor struct LaneAppearanceTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// A window of `appearance` with the lanes of a 2-track package of 1 s at 512 frames per point:
    /// the clips end at 93.75 pt, so the lanes show the lane color past them.
    func lanes(in appearance: NSAppearance.Name) async throws -> (NSWindow, TimelineScrollView, SessionWindow) {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 1), app: app)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1780, height: 400), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        // The appearance comes before the view enters the window (plan gate 2 item 1).
        window.appearance = NSAppearance(named: appearance)
        let view = TimelineScrollView(model: model, studio: studio)
        view.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(view)
        view.update(laneInputs(model, studio))
        view.update(laneInputs(model, studio))
        drawNow(window)
        return (window, view, model)
    }

    /// The pixel of the front surface in lane 1, at x 500 pt (past the clips).
    func lanePixel(_ view: TimelineScrollView) throws -> UInt32? {
        let scale = try #require(view.lanes.surfaces.shown?.scale)
        return view.lanes.surfaces.pixel(column: Int(500 * scale), row: Int(50 * scale))
    }

    @Test func aNewLanesViewInADarkWindowDrawsDarkAtItsFirstDraw() async throws {
        let (window, view, model) = try await lanes(in: .darkAqua)
        #expect(view.lanes.draws >= 1)
        #expect(try lanePixel(view) == 0xFF1E_1F22, "dark at the first draw")
        window.close()
        await model.close()
    }

    /// Code gate 1 item 3: a view in a dark superview enters a dark window and draws dark at its
    /// first draw. The move still gives an appearance change (code gate 2), so the pick at a real
    /// change and the pick at the move each draw dark here. The no-change path, where only the
    /// pick at the move draws dark, is `aLanesViewThatIsDarkAtTheMoveDrawsDarkAtItsFirstDraw`.
    @Test func aLanesViewThatIsDarkBeforeTheWindowDrawsDarkAtItsFirstDraw() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 1), app: app)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1780, height: 400))
        container.appearance = NSAppearance(named: .darkAqua)
        let view = TimelineScrollView(model: model, studio: studio)
        view.frame = container.bounds
        container.addSubview(view)
        try #require(view.lanes.window == nil)
        try #require(view.lanes.effectiveAppearance.name == .darkAqua, "dark before the window")
        let window = NSWindow(
            contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = container
        view.update(laneInputs(model, studio))
        view.update(laneInputs(model, studio))
        drawNow(window)
        #expect(view.lanes.draws >= 1)
        #expect(try lanePixel(view) == 0xFF1E_1F22, "dark at the first draw from a dark superview")
        window.close()
        await model.close()
    }

    /// Code gate 2 item 1: the no-change path of an app in Dark Mode. The lanes view is dark before
    /// it enters the dark window (its own appearance), and its palette is still light, as before
    /// any pick. So the move gives no appearance change, and only a pick at the move draws dark.
    /// The test does not set `NSApp.appearance`: parallel suites share it, and a change of it
    /// replaced the sentinel palette of the L5 test.
    @Test func aLanesViewThatIsDarkAtTheMoveDrawsDarkAtItsFirstDraw() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 1), app: app)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1780, height: 400), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let view = TimelineScrollView(model: model, studio: studio)
        view.lanes.appearance = NSAppearance(named: .darkAqua)
        view.lanes.palette = .light
        try #require(view.lanes.effectiveAppearance.name == .darkAqua, "dark before the window")
        view.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(view)
        view.update(laneInputs(model, studio))
        view.update(laneInputs(model, studio))
        drawNow(window)
        #expect(try lanePixel(view) == 0xFF1E_1F22, "dark at the first draw of a dark app")
        window.close()
        await model.close()
    }

    @Test func anAppearanceChangeRendersOnceInFull() async throws {
        let (window, view, model) = try await lanes(in: .aqua)
        #expect(try lanePixel(view) == 0xFFE8_ECF2, "light lane pixel")
        let draws = view.lanes.draws

        window.appearance = NSAppearance(named: .darkAqua)
        drawNow(window)
        #expect(view.lanes.draws == draws + 1, "one full render")
        #expect(view.lanes.drawnRect == view.shown.intersection(view.lanes.bounds), "one full render: the rect")
        #expect(try lanePixel(view) == 0xFF1E_1F22, "dark lane pixel")

        // AppKit also calls it for a change that keeps the palette, so the view compares.
        window.appearance = NSAppearance(named: .darkAqua)
        view.lanes.viewDidChangeEffectiveAppearance()
        drawNow(window)
        #expect(view.lanes.draws == draws + 1, "no render for the same appearance")

        window.appearance = NSAppearance(named: .aqua)
        drawNow(window)
        #expect(view.lanes.draws == draws + 2, "one full render")
        #expect(try lanePixel(view) == 0xFFE8_ECF2, "light lane pixel")

        // AppKit displays the view at an appearance change; a palette change alone renders too.
        view.lanes.palette = .dark(accent: 0xFFFF_0000)
        drawNow(window)
        #expect(view.lanes.draws == draws + 3, "one full render at a palette change")
        window.close()
        await model.close()
    }
}
