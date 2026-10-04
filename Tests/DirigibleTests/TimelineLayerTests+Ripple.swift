import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// Slice 2b of run 12 (decision 0037): a ripple trim drag draws the later region of the lanes by a
/// shift of the pixels of the front. After each event, the layer contents equal a full render of
/// the same inputs. The fixture of `TimelineLayerTests` (512 frames per point) adds a fade-out on
/// c1, a fade-in on the next clip of t1, a crossfade at the second join of t2, a marker inside the
/// span that the drag deletes, a marker after it, and a selection band on t3 before the edit.
extension TimelineLayerTests {
    @Test func aRippleDragEqualsAFullRender() async throws {
        let (model, studio, window, view) = try await lanes(onScreen: true)
        try studio.edit { session throws(SessionError) in
            try session.setFades(["c1": Fades(fadeIn: 0, fadeOut: 4_800)!])
            let next = session.tracks[0].clips[1].id
            try session.setFades([next: Fades(fadeIn: 4_800, fadeOut: 0)!])
            // A ripple delete at the second join of t2 makes it a butt join, which takes a crossfade.
            try session.rippleDelete(129_536..<130_560, on: ["t2"])
            try session.setCrossfades([session.tracks[1].clips[1].id: 2_048])
            try session.setMarker(Marker(id: "inside", name: "Inside", position: 60_000, kind: .marker))
            try session.setMarker(Marker(id: "after", name: "After", position: 200_000, kind: .chapter))
        }
        model.timeline.scale = TimelineScale(framesPerPoint: 512)
        model.timeline.marks = Marks(inPoint: 5_000, outPoint: 30_000, tracks: ["t3"])
        view.update(inputs(model, studio))
        drawNow(window)
        let shifts = view.lanes.surfaces.shifted
        var failures: [String] = []
        // The end trim zone of c1 on t1 is 4 pt wide.
        let box = try #require(view.lanes.clipFrame("c1"))
        let edge = NSPoint(x: box.maxX - 2, y: box.minY + 10)
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, edge, in: view, flags: .option))
        for (n, dx) in [-7.0, -14, -28, -21, 7, 22, 15, -58, -56.5].enumerated() {
            let x = edge.x + dx
            view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: x, y: edge.y), in: view))
            drawNow(window)
            await Task.yield()
            let wrong = try Self.wrongPixels(view)
            if wrong.count > 0 {
                failures.append("drag \(n) to \(x): \(wrong.count) pixels, the first \(wrong.first!)")
            }
        }
        let preview = view.lanes.inputs?.session != studio.session
        #expect(preview, "the drag shows a preview, box \(box)")
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: edge.x - 56.5, y: edge.y), in: view))
        drawNow(window)
        let wrong = try Self.wrongPixels(view)
        if wrong.count > 0 { failures.append("mouse-up: \(wrong.count) pixels, the first \(wrong.first!)") }
        // A start edge: the clip start stays, and the audio slides under it.
        let second = try #require(view.lanes.inputs?.session.tracks[0].clips[1])
        let start = try #require(view.lanes.clipFrame(second.id))
        let head = NSPoint(x: start.minX + 2, y: start.minY + 10)
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, head, in: view, flags: .option))
        for (n, dx) in [7.0, 20, -10, -30, 4].enumerated() {
            view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: head.x + dx, y: head.y), in: view))
            drawNow(window)
            await Task.yield()
            let wrong = try Self.wrongPixels(view)
            if wrong.count > 0 { failures.append("start drag \(n): \(wrong.count) pixels, the first \(wrong.first!)") }
        }
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: head.x + 4, y: head.y), in: view))
        // One edit that ripples and removes a later marker: its old line must go from the copy. The
        // Marks of the mouse-up are on the clip, after the edit, so they go first.
        model.timeline.marks = Marks()
        view.update(inputs(model, studio))
        drawNow(window)
        let before = view.lanes.surfaces.shifted
        try studio.edit { session throws(SessionError) in
            try session.rippleDelete(10_240..<20_480, on: session.tracks.map(\.id))
            try session.removeMarker("after")
        }
        view.update(inputs(model, studio))
        drawNow(window)
        let removed = try Self.wrongPixels(view)
        if removed.count > 0 { failures.append("removed marker: \(removed.count) pixels, the first \(removed.first!)") }
        #expect(view.lanes.surfaces.shifted == before + 1, "the edit draws by a shift")
        #expect(failures.isEmpty, "\(failures)")
        #expect(view.lanes.surfaces.shifted > shifts + 4, "most drag events draw by a shift")
        window.close()
        await model.close()
    }
}
