import AppKit
import DirigibleCore
import DirigibleTimeline
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Timeline-navigation criterion N12: Option-Page Down and Option-Page Up scroll one view with a
/// 10 % overlap; the scale stays; the origin stops at the ends; a page key during play holds the
/// follow (0017). Page Up and Page Down stay the marker keys (0018). 2 tracks of a 60 s clip.
@Suite(.serialized) @MainActor struct PageKeyTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    @Test func thePageKeysScrollOneViewAndStopAtTheEnds() async throws {
        let (model, _, _, view) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        view.viewWillMove(toWindow: nil)
        view.navigate(.zoomTo(Zoom(scale: TimelineScale(framesPerPoint: 256), origin: 0), stroke: .changed))
        let frames = view.visibleFrames
        model.run(.pageNext)
        #expect(abs(view.origin - 0.9 * frames) <= 256, "a page moves 90 % of the view: \(view.origin)")
        #expect(view.framesPerPoint == 256, "a page keeps the scale")
        model.run(.pagePrevious)
        model.run(.pagePrevious)
        #expect(view.origin == 0, "the first page stops at 0")
        for _ in 0..<20 { model.run(.pageNext) }
        #expect(abs(view.origin + frames - 60 * 48_000 * 1.02) <= 256, "the last page stops at the end")
        await model.close()
    }

    /// U4: Page Up and Page Down with no modifier stay Previous and Next Marker (0018).
    @Test func thePlainPageKeysStayTheMarkerKeys() {
        let items = TimelineCommand.viewItems + TimelineCommand.markerItems
        func command(_ key: KeyEquivalent) -> TimelineCommand? {
            items.first { $0.key == key && $0.modifiers == [] }?.command
        }
        #expect(command(.pageDown) == .nextMarker, "Page Down selects the next marker")
        #expect(command(.pageUp) == .previousMarker, "Page Up selects the previous marker")
    }

    @Test func aPageKeyDuringPlayHoldsTheFollow() async throws {
        let (model, studio, _, view) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        view.viewWillMove(toWindow: nil)
        view.navigate(.zoomTo(Zoom(scale: TimelineScale(framesPerPoint: 256), origin: 0), stroke: .changed))
        studio.play.playback = .playing(Shuttle(direction: .forward, rate: .one))
        model.run(.pageNext)
        #expect(model.timeline.followHeld, "a page key during play holds the follow")
        studio.play.playback = .stopped
        await model.close()
    }
}

/// Criterion N15: after each new way to move the view, the lanes in view equal a full render of
/// the same inputs, at the default state (the fit, origin 0) and zoomed and scrolled.
@Suite(.serialized) @MainActor struct NavigationRedrawTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// The surface shows the columns of the lanes in view now, and its pixels equal a full render.
    func expectFullRender(_ view: TimelineScrollView, _ window: NSWindow, _ step: String) throws {
        drawNow(window)
        let shown = try #require(view.lanes.surfaces.shown, "\(step): no surface")
        let scale = window.backingScaleFactor
        #expect(
            shown.pixels.columns.lowerBound == Int((view.shown.minX * scale).rounded(.down)),
            "\(step): the surface shows columns from \(shown.pixels.columns.lowerBound), the view from \(view.shown.minX)"
        )
        let wrong = try TimelineLayerTests.wrongPixels(view)
        #expect(wrong.count == 0, "\(step): \(wrong.count) wrong pixels, the first \(String(describing: wrong.first))")
    }

    @Test func eachNavigationInputRedrawsTheLanes() async throws {
        let (model, _, window, pane) = try await stripPane(folder, app, onScreen: true)
        let (view, strip) = (pane.scroll, pane.overview)
        for zoomed in [false, true] {
            view.navigate(.fitSession)
            if zoomed {
                view.navigate(
                    .zoomTo(Zoom(scale: TimelineScale(framesPerPoint: 200), origin: 30_000), stroke: .changed))
            }
            let state = zoomed ? "zoomed" : "the fit"
            // The zoom draws first, so the page is the only change of the next draw.
            drawNow(window)
            view.navigate(.page(.forward))
            try expectFullRender(view, window, "a page key redraws the lanes at \(state)")
            view.overviewEvent(.down(x: 900, clicks: 1))
            view.overviewEvent(.up(x: 900))
            try expectFullRender(view, window, "an overview click, \(state)")
            let frame = strip.viewFrame.frame
            view.overviewEvent(.down(x: Double(frame.midX), clicks: 1))
            view.overviewEvent(.drag(x: Double(frame.midX) - 40))
            try expectFullRender(view, window, "a frame drag, \(state)")
            view.overviewEvent(.up(x: Double(frame.midX) - 40))
            let edge = strip.viewFrame.frame.maxX
            view.overviewEvent(.down(x: Double(edge), clicks: 1))
            view.overviewEvent(.drag(x: Double(edge) + 60))
            try expectFullRender(view, window, "an edge drag, \(state)")
            view.overviewEvent(.up(x: Double(edge) + 60))
            view.navigate(.back)
            try expectFullRender(view, window, "Zoom Back, \(state)")
        }
        window.close()
        await model.close()
    }
}
