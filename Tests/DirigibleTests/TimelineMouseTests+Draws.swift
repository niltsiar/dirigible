import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The `pacedDrags` assert of the drag benches on a small session: each drag event draws the lanes
/// exactly once and changes a drawn input. The fixture is 3 tracks of 20 s at 512 frames per point.
/// c1 is trimmed to x 200 to 300 pt on lane 1; c2 and c3 are x 0 to 1875 pt, wider than the view.
extension TimelineMouseTests {
    enum DragKind: String, CaseIterable {
        case move, trim, flag, gain, fade, crossfade, ripple, group, range, triangle
        case endMove = "end move"
        case wideMove = "wide move"
        case wideLaneChange = "wide lane change"

        /// The edit of the session before the drag.
        func prepare(_ s: inout Session) throws(SessionError) {
            switch self {
            case .flag:
                try s.setMarker(Marker(id: "m1", name: "Marker 1", position: 153_600, kind: .marker))
            case .crossfade:
                // c9 joins c1 at x 300 with a crossfade of 20 pt on each side.
                try s.place(Clip(id: "c9", file: "f1", start: 153_600, offset: 300_000, length: 51_200), on: "t1")
                try s.setCrossfades(["c1": 20_480])
            case .ripple:
                // A later clip on t1 (x 400 to 500), which the ripple trim moves.
                try s.place(Clip(id: "c9", file: "f1", start: 204_800, offset: 102_400, length: 51_200), on: "t1")
            case .group:
                try s.trim("c2", to: 102_400..<153_600)
            case .endMove:
                // "end" ends t2 at the session end, x 1855 to 1875 pt.
                try s.place(Clip(id: "end", file: "f1", start: 949_760, offset: 0, length: 10_240), on: "t2")
            default: break
            }
        }

        /// The press, the target of the drags, and the point of drag event `n` (document points;
        /// for the ruler, the ruler y).
        var press: NSPoint {
            switch self {
            case .move, .group: NSPoint(x: 250, y: 10)
            case .trim, .ripple: NSPoint(x: 298, y: 10)
            case .flag: NSPoint(x: 301, y: 10)
            case .gain: NSPoint(x: 250, y: 3)
            case .fade: NSPoint(x: 204, y: 4)
            case .crossfade: NSPoint(x: 280, y: 4)
            case .range: NSPoint(x: 250, y: 80)
            case .triangle: NSPoint(x: 300, y: 20)
            case .endMove: NSPoint(x: 1865, y: 110)
            case .wideMove, .wideLaneChange: NSPoint(x: 300, y: 110)
            }
        }

        func point(_ n: Int) -> NSPoint {
            let (x, y, odd) = (press.x, press.y, n % 2 == 1)
            return switch self {
            case .move: NSPoint(x: x + Double(n), y: y + (odd ? 100 : 0))
            case .trim, .ripple, .crossfade: NSPoint(x: x - Double(3 + n), y: y)
            case .gain: NSPoint(x: x, y: y + (odd ? 20 : 10))
            case .range, .wideLaneChange: NSPoint(x: x + Double(3 + n), y: y + (odd ? 100 : 0))
            default: NSPoint(x: x + Double(3 + n), y: y)
            }
        }

        var onRuler: Bool { self == .flag || self == .triangle }
        /// The range and triangle drags change the Marks of the window model, so SwiftUI updates
        /// the lanes, as in the benches.
        var swiftUI: Bool { self == .range || self == .triangle }
    }

    /// The `pacedDrags` assert of the drag benches (C1 of run 2026-10-08-bench-asserts): each of 3
    /// drag events of each kind draws the lanes exactly once and changes a drawn input.
    @Test(arguments: DragKind.allCases)
    func eachDragEventDrawsTheLanesOnce(kind: DragKind) async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 3, seconds: 20), app: app)
        try studio.edit { s throws(SessionError) in
            try s.trim("c1", to: 102_400..<153_600)
            try kind.prepare(&s)
        }
        let (window, view) = standaloneLanes(model, studio)
        model.timeline.scale = TimelineScale(framesPerPoint: 512)
        switch kind {
        case .group:
            model.timeline.selection = .clips(try #require(ClipSet(["c1", "c2"])))
        case .triangle:
            model.timeline.marks = Marks(inPoint: 153_600, outPoint: 460_800, tracks: ["t1", "t2", "t3"])
        case .endMove:
            view.scroll(toFrame: 243_200)
        default: break
        }
        view.update(laneInputs(model, studio, selection: model.timeline.selection))
        drawNow(window)
        let target: NSView = kind.onRuler ? view.ruler : view.lanes
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try kind.onRuler
                ? rulerMouse(type, point.x, point.y, in: view)
                : mouse(type, point, in: view, flags: kind == .ripple ? .option : [])
        }
        target.mouseDown(with: try event(.leftMouseDown, kind.press))

        for n in 1...3 {
            let (draws, before) = (view.lanes.draws, view.lanes.inputs)
            target.mouseDragged(with: try event(.leftMouseDragged, kind.point(n)))
            if kind.swiftUI { MouseEventBenchmark.swiftUIUpdate(view, model, laneInputs(model, studio)) }
            drawNow(window)

            let drew = view.lanes.draws - draws
            #expect(drew == 1, "\(kind.rawValue) event \(n) drew \(drew) times")
            #expect(view.lanes.inputs != before, "\(kind.rawValue) event \(n) changed no drawn input")
        }
        target.mouseUp(with: try event(.leftMouseUp, kind.point(3)))
        window.close()
        await model.close()
    }
}
