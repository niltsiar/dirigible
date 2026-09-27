import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Criterion 1 of the timeline-layer run: the pixels of the lanes in view after each step.
extension TimelineLayerTests {
    /// Criterion 1: after each step, the layer contents equal a render of the same inputs in the
    /// same window, in 0 pixels: page turns forward and back, scrolls of 20 pt and to 1333.37 pt, a
    /// vertical scroll of 150 pt, clip drags with a selection band over the dragged clip, a trim,
    /// a flag drag, marker adds and undo steps, a resize, a lane height change, and a zoom. At 120
    /// pt clips and at 60 pt clips (1024 frames per point), so labels cross the edges of each
    /// drawn rect.
    @Test func theLanesInViewEqualAFullRender() async throws {
        let (model, studio, window, view) = try await lanes()
        let forward = Playback.playing(Shuttle(direction: .forward, rate: .one))
        let reverse = Playback.playing(Shuttle(direction: .reverse, rate: .one))
        var failures: [String] = []
        func check(_ step: String) throws {
            drawNow(window)
            let wrong = try Self.wrongPixels(view)
            if wrong.count > 0 { failures.append("\(step): \(wrong.count) pixels, the first \(wrong.first!)") }
        }
        func update(laneHeight: Double = 100) {
            view.update(inputs(model, studio, laneHeight: laneHeight))
        }

        for framesPerPoint in [512.0, 1024] {
            model.timeline.scale = TimelineScale(framesPerPoint: framesPerPoint)
            model.timeline.marks = Marks()
            update()
            view.scroll(toFrame: 0)
            try check("\(framesPerPoint): zoom")
            view.tick(playhead: 0, playback: forward)
            for turn in 0..<4 {
                view.tick(playhead: view.origin + 0.95 * view.visibleFrames, playback: forward)
                try check("\(framesPerPoint): page \(turn)")
                await Task.yield()
            }
            for turn in 0..<4 {
                view.tick(playhead: view.origin + 0.04 * view.visibleFrames, playback: reverse)
                try check("\(framesPerPoint): reverse page \(turn)")
                await Task.yield()
            }
            for n in 0..<3 {
                view.scroll(toFrame: view.origin + 20 * framesPerPoint)
                try check("\(framesPerPoint): scroll 20 pt \(n)")
            }
            view.scroll(toFrame: 1333.37 * framesPerPoint)
            try check("\(framesPerPoint): scroll to 1333.37 pt")
            view.contentView.scroll(to: NSPoint(x: view.contentView.bounds.minX, y: view.contentView.bounds.minY + 150))
            view.reflectScrolledClipView(view.contentView)
            try check("\(framesPerPoint): vertical 150 pt")
            view.contentView.scroll(to: NSPoint(x: view.contentView.bounds.minX, y: view.contentView.bounds.minY - 150))
            view.reflectScrolledClipView(view.contentView)
            try check("\(framesPerPoint): vertical back")

            // A band over t1 and t2, then a move of a clip of t2 under it, then a trim of its end.
            let left = view.shown.minX
            model.timeline.marks = Marks(
                inPoint: Frames(Int((left + 100) * framesPerPoint)),
                outPoint: Frames(Int((left + 700) * framesPerPoint)),
                tracks: ["t1", "t2"])
            update()
            try check("\(framesPerPoint): band")
            let clip = try #require(
                view.lanes.inputs?.session.tracks[1].clips.clips(
                    overlapping: Frames(Int((left + 300) * framesPerPoint))..<Frames(Int((left + 301) * framesPerPoint))
                ).first)
            let box = try #require(view.lanes.clipFrame(clip.id))
            let down = NSPoint(x: box.midX, y: box.minY + 10)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
            for n in 1...12 {
                let point = NSPoint(x: down.x + Double(3 + 7 * n), y: down.y + (n > 8 ? 100 : 0))
                view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, point, in: view))
                try check("\(framesPerPoint): drag \(n)")
            }
            view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: down.x + 87, y: down.y + 100), in: view))
            update()
            try check("\(framesPerPoint): drop")
            let trimmed = try #require(view.lanes.clipFrame(clip.id))
            let edge = NSPoint(x: trimmed.maxX - 2, y: trimmed.minY + 10)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, edge, in: view))
            for n in 1...5 {
                view.lanes.mouseDragged(
                    with: try mouse(.leftMouseDragged, NSPoint(x: edge.x - Double(4 * n), y: edge.y), in: view))
                try check("\(framesPerPoint): trim \(n)")
            }
            view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: edge.x - 20, y: edge.y), in: view))
            update()
            try check("\(framesPerPoint): trim up")

            // A marker, its flag drag, then marker adds and undo steps.
            for n in 0..<4 {
                model.addMarker(.marker, at: Frames(Int((left + 50 + 173.3 * Double(n)) * framesPerPoint)))
                update()
                try check("\(framesPerPoint): marker \(n)")
            }
            let flag = (studio.session.markers.values.map { Double($0.position.count) / framesPerPoint }.min() ?? 0) + 1
            view.ruler.mouseDown(with: try rulerMouse(.leftMouseDown, flag, 10, in: view))
            for n in 1...5 {
                view.ruler.mouseDragged(with: try rulerMouse(.leftMouseDragged, flag + Double(3 + 9 * n), 10, in: view))
                try check("\(framesPerPoint): flag \(n)")
            }
            view.ruler.mouseUp(with: try rulerMouse(.leftMouseUp, flag + 48, 10, in: view))
            update()
            for n in 0..<3 {
                model.undo()
                update()
                try check("\(framesPerPoint): undo \(n)")
            }
            await Task.yield()
        }

        window.setContentSize(NSSize(width: window.frame.width - 100, height: window.frame.height - 30))
        view.frame = try #require(window.contentView).bounds
        try check("resize")
        update(laneHeight: 80)
        try check("lane height")
        model.timeline.scale = TimelineScale(framesPerPoint: 900)
        update(laneHeight: 80)
        try check("zoom")

        #expect(failures.isEmpty, "\(failures.count) steps: \(failures.prefix(6))")
        window.close()
        await model.close()
    }
}
