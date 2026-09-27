import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Criterion 1 of the timeline-layer run: the pixels of the lanes in view after each step, and the
/// helpers of the pixel and in-use tests.
extension TimelineLayerTests {
    /// The pixels of the layer contents that differ from a render of the drawn inputs of the lanes
    /// in the same window, by a new renderer and the same label function: the count and the first.
    static func wrongPixels(_ view: TimelineScrollView) throws -> (count: Int, first: (column: Int, row: Int)?) {
        let lanes = view.lanes
        let window = try #require(lanes.surfaces.shown, "the layer shows no window")
        let reference = OwnedPixels.render(try #require(lanes.inputs), window)
        var count = 0
        var first: (Int, Int)?
        for row in window.pixels.rows {
            let shown = try #require(lanes.surfaces.frontRow(row))
            let expected = reference.row(row)
            guard shown != expected else { continue }
            for index in shown.indices where shown[index] != expected[index] {
                count += 1
                if first == nil { first = (window.pixels.columns.lowerBound + index, row) }
            }
        }
        return (count, first)
    }

    /// Holds the surfaces of the lanes that are not the layer contents in layers of `window`, so the
    /// window server uses them (`isInUse`), as it uses a surface that it still shows.
    static func holdOnScreen(_ view: TimelineScrollView, _ window: NSWindow) async throws -> [CALayer] {
        let surfaces = view.lanes.surfaces
        let held = surfaces.surfaces.filter { $0 !== (surfaces.layer.contents as AnyObject?) }
        let layers = held.map { surface in
            let layer = CALayer()
            layer.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
            layer.contents = surface
            window.contentView?.layer?.addSublayer(layer)
            return layer
        }
        drawNow(window)
        await until(limit: .seconds(10), "the window server uses the held surfaces") { held.allSatisfy(\.isInUse) }
        return layers
    }

    /// Criterion 1 in `make check`: the script once at 60 pt clips (1024 frames per point), so
    /// labels cross the edges of each drawn rect, with fewer repeats than the slow form.
    @Test func theLanesInViewEqualAFullRender() async throws {
        try await equalAFullRender(zooms: [1024], repeats: 1)
    }

    /// Criterion 1, the whole script: at 120 pt and at 60 pt clips, with more page turns, scrolls,
    /// and drag events. A slow test: about 15 s of main-actor work in a debug build.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theLanesInViewEqualAFullRenderOverTheWholeScript() async throws {
        try await equalAFullRender(zooms: [512, 1024], repeats: 3)
    }

    /// After each step, the layer contents equal a render of the same inputs in the same window,
    /// in 0 pixels: page turns forward and back, scrolls of 20 pt and to 1333.37 pt, a vertical
    /// scroll of 150 pt, clip drags with a selection band over the dragged clip, a trim, edits that
    /// take turns between two far columns (a partial update copies the rects of several later
    /// commits) and a scroll after them, updates while the window server uses the other surfaces (a new surface), a
    /// vertical scroll to other lanes followed by a drag, a flag drag, marker adds and undo steps,
    /// a resize, a lane height change, and a zoom. Each check yields the main actor.
    func equalAFullRender(zooms: [Double], repeats: Int) async throws {
        let (model, studio, window, view) = try await lanes(onScreen: true)
        let forward = Playback.playing(Shuttle(direction: .forward, rate: .one))
        let reverse = Playback.playing(Shuttle(direction: .reverse, rate: .one))
        var failures: [String] = []
        func check(_ step: String) async throws {
            drawNow(window)
            let wrong = try Self.wrongPixels(view)
            if wrong.count > 0 { failures.append("\(step): \(wrong.count) pixels, the first \(wrong.first!)") }
            await Task.yield()
        }
        func update(laneHeight: Double = 100) {
            view.update(inputs(model, studio, laneHeight: laneHeight))
        }
        func scrollVertically(by dy: Double) {
            view.contentView.scroll(to: NSPoint(x: view.contentView.bounds.minX, y: view.contentView.bounds.minY + dy))
            view.reflectScrolledClipView(view.contentView)
        }

        for framesPerPoint in zooms {
            let zoom = "\(Int(framesPerPoint))"
            model.timeline.scale = TimelineScale(framesPerPoint: framesPerPoint)
            model.timeline.marks = Marks()
            update()
            view.scroll(toFrame: 0)
            try await check("\(zoom): zoom")
            view.tick(playhead: 0, playback: forward)
            for turn in 0..<1 + repeats {
                view.tick(playhead: view.origin + 0.95 * view.visibleFrames, playback: forward)
                try await check("\(zoom): page \(turn)")
            }
            for turn in 0..<repeats {
                view.tick(playhead: view.origin + 0.04 * view.visibleFrames, playback: reverse)
                try await check("\(zoom): reverse page \(turn)")
            }
            for n in 0..<1 + repeats {
                view.scroll(toFrame: view.origin + 20 * framesPerPoint)
                try await check("\(zoom): scroll 20 pt \(n)")
            }
            view.scroll(toFrame: 1333.37 * framesPerPoint)
            try await check("\(zoom): scroll to 1333.37 pt")
            scrollVertically(by: 150)
            try await check("\(zoom): vertical 150 pt")
            scrollVertically(by: -150)
            try await check("\(zoom): vertical back")

            // A band over t1 and t2, then a move of a clip of t2 under it, then a trim of its end.
            let left = view.shown.minX
            func frame(_ x: Double) -> Frames { Frames(Int((left + x) * framesPerPoint)) }
            model.timeline.marks = Marks(inPoint: frame(100), outPoint: frame(700), tracks: ["t1", "t2"])
            update()
            try await check("\(zoom): band")
            let clip = try #require(
                view.lanes.inputs?.session.tracks[1].clips.clips(overlapping: frame(300)..<frame(301)).first)
            let box = try #require(view.lanes.clipFrame(clip.id))
            let down = NSPoint(x: box.midX, y: box.minY + 10)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
            let drags = 4 * repeats + 2
            for n in 1...drags {
                let point = NSPoint(x: down.x + Double(3 + 7 * n), y: down.y + (n > drags - 2 ? 100 : 0))
                view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, point, in: view))
                try await check("\(zoom): drag \(n)")
            }
            view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: down.x + 87, y: down.y + 100), in: view))
            update()
            try await check("\(zoom): drop")
            let trimmed = try #require(view.lanes.clipFrame(clip.id))
            let edge = NSPoint(x: trimmed.maxX - 2, y: trimmed.minY + 10)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, edge, in: view))
            for n in 1...1 + repeats {
                view.lanes.mouseDragged(
                    with: try mouse(.leftMouseDragged, NSPoint(x: edge.x - Double(4 * n), y: edge.y), in: view))
                try await check("\(zoom): trim \(n)")
            }
            view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: edge.x - 20, y: edge.y), in: view))
            update()
            try await check("\(zoom): trim up")

            // Edits that take turns between two far columns: each partial update copies the rects
            // of the commits after its surface, on both sides of the view.
            for n in 0..<4 + 2 * repeats {
                let x = n % 2 == 0 ? 60.0 + Double(n) : 1300.0 - Double(n)
                model.timeline.marks = Marks(inPoint: frame(x), outPoint: frame(x + 30), tracks: ["t1"])
                update()
                try await check("\(zoom): far edit \(n)")
            }
            // A scroll after partial updates in one window: the picked surface shows the window of
            // the front, not the new one, so it copies the overlap, shifted.
            view.scroll(toFrame: view.origin + 20 * framesPerPoint)
            try await check("\(zoom): scroll after the edits")
            // Updates while the window server uses the other surfaces: each makes a new surface.
            let held = try await Self.holdOnScreen(view, window)
            for n in 0..<2 {
                model.timeline.marks = Marks(inPoint: frame(400), outPoint: frame(450 + Double(n)), tracks: ["t2"])
                update()
                try await check("\(zoom): held \(n)")
            }
            for layer in held { layer.removeFromSuperlayer() }
            // A vertical scroll to other lanes, then a drag on them.
            scrollVertically(by: 200)
            try await check("\(zoom): vertical 200 pt")
            let lower = try #require(
                view.lanes.inputs?.session.tracks[3].clips.clips(overlapping: frame(500)..<frame(501)).first)
            let lowerBox = try #require(view.lanes.clipFrame(lower.id))
            let start = NSPoint(x: lowerBox.midX, y: lowerBox.minY + 10)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, start, in: view))
            for n in 1...4 {
                view.lanes.mouseDragged(
                    with: try mouse(.leftMouseDragged, NSPoint(x: start.x + Double(3 + 5 * n), y: start.y), in: view))
                try await check("\(zoom): lower drag \(n)")
            }
            view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: start.x + 23, y: start.y), in: view))
            update()
            scrollVertically(by: -200)
            try await check("\(zoom): vertical back 200 pt")

            // A marker, its flag drag, then marker adds and undo steps.
            for n in 0..<1 + repeats {
                model.addMarker(.marker, at: frame(50 + 173.3 * Double(n)))
                update()
                try await check("\(zoom): marker \(n)")
            }
            let flag = (studio.session.markers.values.map { Double($0.position.count) / framesPerPoint }.min() ?? 0) + 1
            view.ruler.mouseDown(with: try rulerMouse(.leftMouseDown, flag, 10, in: view))
            for n in 1...1 + repeats {
                view.ruler.mouseDragged(with: try rulerMouse(.leftMouseDragged, flag + Double(3 + 9 * n), 10, in: view))
                try await check("\(zoom): flag \(n)")
            }
            view.ruler.mouseUp(with: try rulerMouse(.leftMouseUp, flag + 48, 10, in: view))
            update()
            for n in 0..<repeats {
                model.undo()
                update()
                try await check("\(zoom): undo \(n)")
            }
        }

        window.setContentSize(NSSize(width: window.frame.width - 100, height: window.frame.height - 30))
        view.frame = try #require(window.contentView).bounds
        try await check("resize")
        update(laneHeight: 80)
        try await check("lane height")
        model.timeline.scale = TimelineScale(framesPerPoint: 900)
        update(laneHeight: 80)
        try await check("zoom")

        #expect(failures.isEmpty, "\(failures.count) steps: \(failures.prefix(6))")
        window.close()
        await model.close()
    }
}
