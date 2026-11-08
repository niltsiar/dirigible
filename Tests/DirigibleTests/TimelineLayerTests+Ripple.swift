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
    /// The share of the pixels of a drag preview at a zoom that is not a whole number of frames
    /// per point that can differ from a full render (code gate 1 item 1): the move is a whole
    /// number of columns, but its frames are rounded, so a peak or an edge can move by one column.
    /// The mouse-up draws the lanes in full.
    static let previewTolerance = 0.01

    /// At 512 frames per point the preview is exact. At 511.3, see `previewTolerance`.
    @Test(arguments: [512.0, 511.3])
    func aRippleDragEqualsAFullRender(framesPerPoint: Double) async throws {
        let (model, studio, window, view) = try await lanes(onScreen: true)
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setFades(["c1": Fades(fadeIn: 0, fadeOut: 4_800)!])
            let next = session.tracks[0].clips[1].id
            try session.setFades([next: Fades(fadeIn: 4_800, fadeOut: 0)!])
            // A ripple delete at the second join of t2 makes it a butt join, which takes a crossfade.
            try session.rippleDelete(129_536..<130_560, on: ["t2"], naming: [])
            try session.setCrossfades([session.tracks[1].clips[1].id: 2_048])
            try session.setMarker(Marker(id: "inside", name: "Inside", position: 60_000, kind: .marker))
            try session.setMarker(Marker(id: "after", name: "After", position: 200_000, kind: .chapter))
        }
        model.timeline.scale = TimelineScale(framesPerPoint: framesPerPoint)
        let whole = framesPerPoint == framesPerPoint.rounded()
        model.timeline.marks = Marks(inPoint: 5_000, outPoint: 30_000, tracks: ["t3"])
        view.update(inputs(model, studio))
        drawNow(window)
        let shifts = view.lanes.surfaces.shifted
        var failures: [String] = []
        /// A drag event may differ from a full render by `previewTolerance` at a zoom that is not
        /// whole; a mouse-up or an edit by none.
        func check(_ step: String, preview: Bool) throws {
            let wrong = try Self.wrongPixels(view)
            let pixels = try #require(view.lanes.surfaces.shown).pixels
            let allowed =
                preview && !whole ? Double(pixels.columns.count * pixels.rows.count) * Self.previewTolerance : 0
            if Double(wrong.count) > allowed {
                failures.append("\(step): \(wrong.count) pixels, the first \(String(describing: wrong.first))")
            }
        }
        // The end trim zone of c1 on t1 is 4 pt wide.
        let box = try #require(view.lanes.clipFrame("c1"))
        let edge = NSPoint(x: box.maxX - 2, y: box.minY + 10)
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, edge, in: view, flags: .option))
        for (n, dx) in [-7.0, -14, -28, -21, 7, 22, 15, -58, -56.5].enumerated() {
            let x = edge.x + dx
            view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: x, y: edge.y), in: view))
            drawNow(window)
            await Task.yield()
            try check("drag \(n) to \(x)", preview: true)
        }
        let preview = view.lanes.inputs?.session != studio.session
        #expect(preview, "the drag shows a preview, box \(box)")
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: edge.x - 56.5, y: edge.y), in: view))
        drawNow(window)
        try check("mouse-up", preview: false)
        // Code gate 2 item 2: an undo and a redo of the ripple are no preview, so they are exact.
        // The Marks of the commit go in first, so the undo changes only the session.
        view.update(inputs(model, studio))
        drawNow(window)
        for (step, action) in [("undo", model.undo), ("redo", model.redo)] {
            action()
            view.update(inputs(model, studio))
            drawNow(window)
            try check(step, preview: false)
        }
        // A second drag of the same edge, with the range of c1 on t1: the out line sits at the dragged
        // edge, so the shift copies from 1 pt past it and the line stays out of the copy.
        let c1 = try #require(studio.session.clip("c1")).clip
        model.timeline.marks = Marks(inPoint: c1.start, outPoint: c1.end, tracks: ["t1"])
        view.update(inputs(model, studio))
        drawNow(window)
        #expect(view.lanes.inputs?.marks.outPoint == c1.end, "the range of c1 is drawn")
        var marked = [view.lanes.surfaces.shifted]
        let again = try #require(view.lanes.clipFrame("c1"))
        let end = NSPoint(x: again.maxX - 2, y: again.minY + 10)
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, end, in: view, flags: .option))
        for (n, dx) in [-6.0, -12].enumerated() {
            view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: end.x + dx, y: end.y), in: view))
            drawNow(window)
            await Task.yield()
            try check("marked drag \(n)", preview: true)
            marked.append(view.lanes.surfaces.shifted)
        }
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: end.x - 12, y: end.y), in: view))
        #expect(marked == [marked[0], marked[0] + 1, marked[0] + 2], "a range at the dragged edge keeps the shift")
        // A start edge: the clip start stays, and the audio slides under it.
        let second = try #require(view.lanes.inputs?.session.tracks[0].clips[1])
        let start = try #require(view.lanes.clipFrame(second.id))
        let head = NSPoint(x: start.minX + 2, y: start.minY + 10)
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, head, in: view, flags: .option))
        for (n, dx) in [7.0, 20, -10, -30, 4].enumerated() {
            view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: head.x + dx, y: head.y), in: view))
            drawNow(window)
            await Task.yield()
            try check("start drag \(n)", preview: true)
        }
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: head.x + 4, y: head.y), in: view))
        drawNow(window)
        try check("start mouse-up", preview: false)
        // One edit that ripples and removes a later marker: its old line must go from the copy. The
        // Marks of the mouse-up are on the clip, after the edit, so they go first.
        model.timeline.marks = Marks()
        view.update(inputs(model, studio))
        drawNow(window)
        let before = view.lanes.surfaces.shifted
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.rippleDelete(10_240..<20_480, on: session.tracks.map(\.id), naming: [])
            try session.removeMarker("after")
        }
        view.update(inputs(model, studio))
        drawNow(window)
        try check("removed marker", preview: false)
        // The edit moves 10 240 frames: a whole number of columns only at a whole zoom.
        #expect(view.lanes.surfaces.shifted == before + (whole ? 1 : 0), "the edit draws by a shift at a whole zoom")
        // Code gate 2 item 2: an edit outside a gesture whose move is 41 columns at 511.3 frames
        // per point within one frame (10 482 frames) takes no rounded shift: it draws in full.
        let edited = view.lanes.surfaces.shifted
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.rippleDelete(5_000..<15_482, on: session.tracks.map(\.id), naming: [])
        }
        view.update(inputs(model, studio))
        drawNow(window)
        try check("rounded edit", preview: false)
        if !whole { #expect(view.lanes.surfaces.shifted == edited, "an edit takes a rounded shift") }
        #expect(failures.isEmpty, "\(failures)")
        #expect(view.lanes.surfaces.shifted > shifts + 4, "most drag events draw by a shift")
        window.close()
        await model.close()
    }

    /// C53 (decision 0073): a ripple trim drag over a track that follows ripples and does not move
    /// draws by a shift, and the copy keeps the pixels of the follow lane: it draws there only the
    /// old and the new line of a marker that moves, 6 pt apart, in one strip. Controls: the follow
    /// lane in its own strip (it draws), the follow lane moved with the other lanes (its waveform
    /// moves), and no marker line on the follow lane (the old line stays).
    @Test(arguments: [false, true])
    func aStillLaneDrawsOnlyTheMovedMarkerLines(marker: Bool) async throws {
        let (model, studio, window, view) = try await lanes(tracks: 1, onScreen: true)
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.addTrack("bed", name: "Bed", layout: .mono)
            try session.place(
                Clip(id: "bed", file: "f1", start: 0, offset: 0, length: Frames(Self.frames)), on: "bed")
            try session.setFollowTrack(true, tracks: ["bed"])
            if marker { try session.setMarker(Marker(id: "late", name: "Late", position: 150_000, kind: .marker)) }
        }
        model.timeline.scale = TimelineScale(framesPerPoint: 512)
        // The Marks of a ripple commit are on the clip, so the press keeps the selection.
        let c1 = try #require(studio.session.clip("c1")).clip
        model.timeline.marks = Marks(inPoint: c1.start, outPoint: c1.end, tracks: ["t1"])
        view.update(inputs(model, studio))
        drawNow(window)
        let shown = try #require(view.lanes.surfaces.shown)
        #expect(shown.pixels.rows.count == 2 * 200, "the two lanes of 100 pt at scale 2 are in view: \(shown.pixels)")
        let bedRows = shown.rows(of: 1..<2)
        let bed = studio.session.clip("bed")?.clip
        let before = view.lanes.surfaces.shifted
        let box = try #require(view.lanes.clipFrame("c1"))
        let edge = NSPoint(x: box.maxX - 2, y: box.minY + 10)
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, edge, in: view, flags: .option))
        var failures: [String] = []
        for dx in [-6.0, -12, -18] {
            let old = view.lanes.inputs?.session.markers["late"]?.position
            view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: edge.x + dx, y: edge.y), in: view))
            drawNow(window)
            await Task.yield()
            let wrong = try Self.wrongPixels(view)
            if wrong.count > 0 {
                failures.append("drag \(dx): \(wrong.count) pixels, the first \(String(describing: wrong.first))")
            }
            // The columns of the old and the new marker line, with the 1 pt on each side of a stray.
            let new = view.lanes.inputs?.session.markers["late"]?.position
            if marker, old == new { failures.append("drag \(dx): the marker did not move") }
            let geometry = try #require(view.lanes.inputs?.geometry)
            let xs = [old, new].compactMap { $0 }.map { geometry.x(of: $0) }
            let (low, high) = (((xs.min() ?? 0) - 1) * shown.scale, ((xs.max() ?? 0) + 2) * shown.scale)
            let lines = xs.isEmpty ? 0..<0 : Int(low.rounded(.down))..<Int(high.rounded(.up))
            let drawn = view.lanes.surfaces.lastDrawn.filter { $0.rows.overlaps(bedRows) }
            if drawn.contains(where: { $0.columns.clamped(to: lines) != $0.columns }) {
                failures.append("drag \(dx): the follow lane drew \(drawn), the marker lines take \(lines)")
            }
            if marker, drawn.count != 1 {
                failures.append("drag \(dx): the lines 6 pt apart drew in \(drawn.count) strips, not 1")
            }
        }
        #expect(
            view.lanes.inputs?.session.clip("c1")?.clip.end == c1.end - Frames(18 * 512), "the drag shows a preview")
        #expect(view.lanes.inputs?.session.clip("bed")?.clip == bed, "the bed does not move")
        #expect(view.lanes.surfaces.shifted == before + 3, "each drag event draws by a shift")
        #expect(failures.isEmpty, "\(failures)")
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: edge.x - 18, y: edge.y), in: view))
        window.close()
        await model.close()
    }
}
