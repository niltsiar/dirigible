import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 2026-10-11-ui-polish-header C11 and C12: the lane of each track that the headers show as
/// selected gets one tint layer in the accent color, so the row and its lane read as one track.
@Suite(.serialized) @MainActor struct LaneTintTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    func open() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        try await openLanes(app, try await timelinePackage(in: folder.url, tracks: 3, seconds: 20, audio: true))
    }

    /// The frames of the tint layers, top lane first.
    func tints(_ view: TimelineScrollView) -> [NSRect] {
        (view.lanes.tint.layer.sublayers ?? []).map(\.frame).sorted { $0.minY < $1.minY }
    }

    /// The rect of lane `lane` in the document view.
    func laneRect(_ lane: Int, _ view: TimelineScrollView) throws -> NSRect {
        let height = try #require(view.lanes.inputs?.laneHeight)
        return NSRect(x: 0, y: Double(lane) * height, width: view.lanes.bounds.width, height: height)
    }

    /// The accent of the palette at `alpha`, as the tint layer has it.
    func expected(_ palette: LanePalette, alpha: Double) -> [Double] {
        let accent = palette.outline
        return [accent >> 16 & 0xFF, accent >> 8 & 0xFF, accent & 0xFF].map { Double($0) / 255 } + [alpha]
    }

    /// C11: a header click and a range on t2 tint the lane of t2, Esc removes the tint, and a clip
    /// set gives none. The accent is at 8 % in light mode and at 10 % in Dark Mode.
    @Test func aSelectedTrackTintsItsLane() async throws {
        let (model, _, window, view) = try await open()
        drawNow(window)
        #expect(tints(view).isEmpty, "no tint with no selection")

        model.clickHeader("t2", flags: [])
        await until("the tint of t2") { tints(view).count == 1 }
        #expect(tints(view) == [try laneRect(1, view)], "a header click tints the lane of t2")
        for (appearance, alpha) in [(NSAppearance.Name.aqua, 0.08), (.darkAqua, 0.10)] {
            window.appearance = NSAppearance(named: appearance)
            drawNow(window)
            let palette = LanePalette.pick(for: try #require(NSAppearance(named: appearance)))
            let color = try #require(view.lanes.tint.layer.sublayers?.first?.backgroundColor?.components)
            let wanted = expected(palette, alpha: alpha)
            #expect(zip(color, wanted).allSatisfy { abs($0 - $1) < 0.002 }, "\(appearance): \(color), \(wanted)")
        }
        window.appearance = NSAppearance(named: .aqua)

        model.run(.deselectAll)
        await until("no tint after Esc") { tints(view).isEmpty }
        model.timeline.selection = .range(Marks(inPoint: 0, outPoint: 48_000, tracks: ["t2"]))
        await until("the tint of a range") { tints(view).count == 1 }
        #expect(tints(view) == [try laneRect(1, view)], "a range on t2 tints the lane of t2")
        model.timeline.selection = .clips(try #require(ClipSet(["c2"])))
        await until("no tint for a clip set") { tints(view).isEmpty }
        #expect(tints(view).isEmpty, "a clip set gives no tint (decision 0038)")
        await model.close()
    }

    /// C12: a range drag over the same track changes no tint layer.
    @Test func aRangeDragKeepsTheTint() async throws {
        let (model, _, window, view) = try await open()
        let laneHeight = try #require(view.lanes.inputs?.laneHeight)
        let y = laneHeight * 0.9
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 100, y: y), in: view))
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 110, y: y), in: view))
        await until("the tint of t1") { tints(view).count == 1 }
        let layers = (view.lanes.tint.layer.sublayers ?? []).map(ObjectIdentifier.init)
        for n in 1...10 {
            let point = NSPoint(x: 110 + Double(n) * 10, y: y)
            view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, point, in: view))
            drawNow(window)
        }
        #expect((view.lanes.tint.layer.sublayers ?? []).map(ObjectIdentifier.init) == layers, "the same layers")
        #expect(tints(view) == [try laneRect(0, view)], "the tint stays on the lane of t1")
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 210, y: y), in: view))
        await model.close()
    }

    /// The update guard reads the lane rects: a lane height step, a track move, and a track delete
    /// move or remove the tint.
    @Test func aLaneChangeMovesTheTint() async throws {
        let (model, studio, _, view) = try await open()
        model.clickHeader("t3", flags: [])
        await until("the tint of t3") { tints(view).count == 1 }
        #expect(tints(view) == [try laneRect(2, view)], "the default lane height")

        let height = try #require(view.lanes.inputs?.laneHeight)
        model.timeline.laneHeight = .fixed(height == 80 ? 100 : 80)
        await until("the new lane height") { view.lanes.inputs?.laneHeight != height }
        #expect(tints(view) == [try laneRect(2, view)], "a lane height change moves the tint")

        try studio.edit { session throws(SessionError) in try session.removeTrack("t1") }
        await until("t3 is lane 1") { view.lanes.inputs?.session.tracks.count == 2 }
        #expect(tints(view) == [try laneRect(1, view)], "a track move moves the tint")

        try studio.edit { session throws(SessionError) in try session.removeTrack("t3") }
        await until("no t3") { view.lanes.inputs?.session.tracks.count == 1 }
        #expect(tints(view).isEmpty, "a track delete removes the tint")
        await model.close()
    }
}
