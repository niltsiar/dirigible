import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// A full redraw request draws the lanes in view once. AppKit answers `needsDisplay = true` with a
/// `setNeedsDisplay` call for the infinite rect, so `pending` can hold two rects that hold each other.
extension TimelineLayerTests {
    /// A new scale, a new lane height, and a new palette each draw the whole window as one part.
    @Test func aFullRedrawRequestDrawsTheWindowOnce() async throws {
        let (model, studio, window, view) = try await lanes(onScreen: true)
        func redraw(_ change: String, _ apply: () -> Void) throws {
            let before = view.lanes.draws
            apply()
            drawNow(window)
            let surfaces = view.lanes.surfaces
            let shown = try #require(surfaces.shown)
            #expect(view.lanes.draws == before + 1, "\(change): \(view.lanes.draws - before) draws")
            #expect(
                surfaces.lastDrawn == [shown.pixels],
                "\(change): \(surfaces.lastDrawn.count) parts \(surfaces.lastDrawn)")
        }

        try redraw("new scale") {
            model.timeline.scale = TimelineScale(framesPerPoint: 256)
            view.update(inputs(model, studio))
        }
        try redraw("new lane height") { view.update(inputs(model, studio, laneHeight: 120)) }
        try redraw("new palette") { view.lanes.palette = .dark(accent: 0xFF44_5566) }

        window.close()
        await model.close()
    }

    /// `show` drops a changed rect that another changed rect holds, and keeps rects that do not hold
    /// each other apart.
    @Test func aChangedRectThatAnotherHoldsDrawsNoPartOfItsOwn() throws {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 300)
        let window = try #require(LaneWindow(view: rect, bounds: rect, laneHeight: 100, lanes: 3, scale: 2, room: 100))
        let lanes = (0..<3).map { PixelRect(columns: window.pixels.columns, rows: window.rows(of: $0..<$0 + 1)) }
        let cases: [(changed: [PixelRect], parts: [PixelRect])] = [
            ([window.pixels, window.pixels], [window.pixels]),
            ([window.pixels, lanes[1]], [window.pixels]),
            ([lanes[1], window.pixels], [window.pixels]),
            ([lanes[0], lanes[2]], [lanes[0], lanes[2]]),
        ]

        for (changed, parts) in cases {
            let surfaces = LaneSurfaces()
            _ = surfaces.show(window, changed: [window.pixels]) {
                $0.fill(0, columns: $0.rect.columns, rows: $0.rect.rows)
            }
            var draws = 0
            _ = surfaces.show(window, changed: changed) {
                draws += 1
                $0.fill(1, columns: $0.rect.columns, rows: $0.rect.rows)
            }
            #expect(surfaces.lastDrawn == parts, "changed \(changed): drew \(surfaces.lastDrawn)")
            #expect(draws == parts.count, "changed \(changed): \(draws) draw calls")
        }
    }
}
