import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// Multi-clip-selection C15b and C15c (decision 0038): a group drag of the last clip of each lane
/// draws the same pixels as a full render after each event, also by the shift path of 0037 when it
/// takes the drag. The fixture of `TimelineLayerTests`, cut to 1,200 pt so that the last clips are
/// in view, at a whole zoom and at one that is not whole. Origin 0; a second drag after a commit.
extension TimelineLayerTests {
    @Test(arguments: [512.0, 511.3])
    func aGroupDragDrawsAsAFullDraw(framesPerPoint: Double) async throws {
        let (model, studio, window, view) = try await lanes(onScreen: true)
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.clear(600_000..<Frames(Self.frames), on: session.tracks.map(\.id))
        }
        model.timeline.scale = TimelineScale(framesPerPoint: framesPerPoint)
        let last = studio.session.tracks.compactMap { $0.clips.last?.id }
        model.timeline.selection = .clips(try #require(ClipSet(Set(last))))
        view.update(inputs(model, studio))
        drawNow(window)
        var failures: [String] = []
        for round in 1...2 {
            let box = try #require(view.lanes.clipFrame(last[0]))
            let start = NSPoint(x: box.midX, y: box.minY + 10)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, start, in: view))
            for (n, dx) in [5.0, 12.5, 30, 22, -40].enumerated() {
                let point = NSPoint(x: start.x + dx, y: start.y)
                view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, point, in: view))
                drawNow(window)
                await Task.yield()
                let wrong = try Self.wrongPixels(view)
                if wrong.count > 0 { failures.append("round \(round) drag \(n): \(wrong.count) pixels at \(wrong)") }
            }
            #expect(view.lanes.inputs?.session != studio.session, "round \(round): the drag shows a preview")
            view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: start.x - 40, y: start.y), in: view))
            view.update(inputs(model, studio))
            drawNow(window)
            if try Self.wrongPixels(view).count > 0 { failures.append("round \(round) mouse-up") }
            #expect(model.timeline.selection == .clips(try #require(ClipSet(Set(last)))), "the set stays")
        }
        #expect(failures.isEmpty, "\(failures)")
        window.close()
        await model.close()
    }
}
