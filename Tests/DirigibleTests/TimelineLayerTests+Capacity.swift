import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Criterion 7 of the timeline-layer run: the number and the capacity of the surfaces, and the
/// part of the layer that shows.
extension TimelineLayerTests {
    /// Criterion 7: the lanes hold 4 surfaces or fewer, each of the capacity of the current view,
    /// after each of 8 page turns, 60 drag events, 40 marker adds, 40 undo steps, 5 window resizes,
    /// and updates while the window server uses the other surfaces.
    @Test func theSurfacesStayBounded() async throws {
        let (model, studio, window, view) = try await lanes(tracks: 2, onScreen: true)
        var failures: [String] = []
        func check(_ step: String) {
            let surfaces = view.lanes.surfaces
            guard let capacity = surfaces.shown?.capacity else { return failures.append("\(step): no window") }
            let sizes = surfaces.surfaces.map { "\($0.width)x\($0.height)" }
            let bytes = surfaces.surfaces.first { $0.width == capacity.columns }?.allocationSize ?? 0
            if surfaces.count > 4 || sizes.contains(where: { $0 != "\(capacity.columns)x\(capacity.rows)" })
                || surfaces.bytes > 4 * bytes
            {
                failures.append("\(step): \(sizes), capacity \(capacity.columns)x\(capacity.rows)")
            }
        }
        view.tick(playhead: 0, playback: .playing(Shuttle(direction: .forward, rate: .one)))
        for turn in 0..<8 {
            view.tick(
                playhead: view.origin + 0.95 * view.visibleFrames,
                playback: .playing(Shuttle(direction: .forward, rate: .one)))
            drawNow(window)
            check("turn \(turn)")
            await Task.yield()
        }
        view.scroll(toFrame: 0)
        drawNow(window)
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 150, y: 10), in: view))
        for n in 1...60 {
            view.lanes.mouseDragged(
                with: try mouse(.leftMouseDragged, NSPoint(x: 150 + Double(3 + n), y: 10), in: view))
            drawNow(window)
            check("drag \(n)")
            await Task.yield()
        }
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 213, y: 10), in: view))
        for n in 0..<40 {
            model.addMarker(.marker, at: Frames(n * 18_000))
            view.update(inputs(model, studio))
            drawNow(window)
            check("marker \(n)")
            await Task.yield()
        }
        for n in 0..<40 {
            model.undo()
            view.update(inputs(model, studio))
            drawNow(window)
            check("undo \(n)")
            await Task.yield()
        }
        // Each resize makes the view smaller, so a kept surface is larger than the new capacity. The
        // wait lets the window server free the other surfaces first, so the pick can keep one.
        for n in 0..<5 {
            try await Task.sleep(for: .milliseconds(40))
            window.setContentSize(NSSize(width: window.frame.width - 40, height: window.frame.height - 20))
            view.frame = try #require(window.contentView).bounds
            drawNow(window)
            check("resize \(n)")
            await Task.yield()
        }
        // Four scrolls fill the slots, then the window server uses every surface but the contents.
        for n in 0..<4 {
            view.scroll(toFrame: view.origin + 20 * view.framesPerPoint)
            drawNow(window)
            check("fill \(n)")
        }
        let held = try await Self.holdOnScreen(view, window)
        #expect(held.count == 3, "the held surfaces")
        for n in 0..<3 {
            view.scroll(toFrame: view.origin + 20 * view.framesPerPoint)
            drawNow(window)
            check("held \(n)")
        }

        #expect(failures.isEmpty, "\(failures.prefix(5))")
        #expect(studio.session.markers.isEmpty, "each undo takes a marker back")
        for layer in held { layer.removeFromSuperlayer() }
        window.close()
        await model.close()
    }

    /// Criterion 7: a window at a fraction of a pixel in both axes fits the capacity. The clip
    /// view scrolls by whole pixels, so only a view rect of another caller has such an origin.
    @Test func aFractionalWindowFitsTheCapacity() throws {
        let bounds = CGRect(x: 0, y: 0, width: 20_000, height: 800)
        for (x, y) in [(1333.37, 37.3), (0.2, 99.9), (18_000.49, 250.01)] {
            let window = try #require(
                LaneWindow(
                    view: CGRect(x: x, y: y, width: 1440, height: 376), bounds: bounds, laneHeight: 100, lanes: 8,
                    scale: 2, room: 1440))
            #expect(window.pixels.columns.count <= window.capacity.columns, "columns at \(x)")
            #expect(window.pixels.rows.count <= window.capacity.rows, "rows at \(y)")
        }
    }

    /// Run 1b fallback 1 (decision 0023, "Surface capacity"): the columns of the capacity come from
    /// the clip view width (`room`) when it is wider than the view, so a header drag keeps it.
    @Test func theCapacityKeysOnTheClipViewWidth() throws {
        let bounds = CGRect(x: 0, y: 0, width: 20_000, height: 800)
        func capacity(view width: Double, room: Double) throws -> SurfaceCapacity {
            try #require(
                LaneWindow(
                    view: CGRect(x: 0, y: 0, width: width, height: 376), bounds: bounds, laneHeight: 100, lanes: 8,
                    scale: 2, room: room)
            ).capacity
        }
        #expect(try capacity(view: 1300, room: 1780).columns == 3561, "capacity from the room")
        #expect(try capacity(view: 1600, room: 1780).columns == 3561, "capacity from the room")
        #expect(try capacity(view: 1440, room: 1000).columns == 2881, "capacity from the view")
    }

    /// The layer shows the used part of the contents with no scale: its frame is whole pixels and
    /// holds the lanes in view, and `contentsRect` times the capacity is the window in pixels. The
    /// playhead is over it. The origin is 1333.37 pt, a fraction of a pixel.
    @Test func theLayerShowsTheUsedPartUnscaled() async throws {
        let (model, _, window, view) = try await lanes()
        view.scroll(toFrame: 1333.37 * view.framesPerPoint)
        drawNow(window)

        let lanes = view.lanes
        let layer = lanes.surfaces.layer
        let shown = try #require(lanes.surfaces.shown)
        let scale = shown.scale
        let frame = layer.frame
        for value in [frame.minX, frame.minY, frame.width, frame.height] {
            #expect((value * scale).rounded() == value * scale, "\(frame)")
        }
        #expect(frame.contains(view.shown.intersection(lanes.bounds)), "\(frame) holds \(view.shown)")
        let contents = layer.contentsRect
        #expect(contents.origin == .zero)
        #expect(abs(contents.width * Double(shown.capacity.columns) - Double(shown.pixels.columns.count)) < 1e-9)
        #expect(abs(contents.height * Double(shown.capacity.rows) - Double(shown.pixels.rows.count)) < 1e-9)
        #expect(frame.width * scale == Double(shown.pixels.columns.count))
        #expect(lanes.playhead.zPosition > layer.zPosition)
        window.close()
        await model.close()
    }
}
