import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 2026-10-11-ui-polish-header C3b: a two-line row of 56 to 79 pt has no room for the state
/// text and the "Privacy…" button, so the state is an orange symbol button that opens the
/// settings, with the full sentence as its help tag.
extension HeaderRowTests {
    /// The AppKit bezel views of the buttons in row `lane`: a text button has one; a borderless
    /// SwiftUI symbol button has none.
    func bezels(_ host: NSView, lane: Int, laneHeight: Double) -> Int {
        func leaves(_ view: NSView) -> [NSView] { view.subviews.isEmpty ? [view] : view.subviews.flatMap(leaves) }
        return leaves(host).filter { leaf in
            let frame = leaf.convert(leaf.bounds, to: host)
            return String(describing: type(of: leaf)) == "NSButtonBezelView"
                && frame.midY >= Double(lane) * laneHeight && frame.midY < Double(lane + 1) * laneHeight
        }.count
    }

    @Test func aMidRowShowsTheStateAsASymbolButton() async throws {
        let (model, studio) = try await model()
        studio.liveTracks["t1"] = LiveTrack(state: .noSound, droppedFrames: 0, peak: 0)
        studio.liveTracks["t2"] = LiveTrack(state: .recording, droppedFrames: 0, peak: 0)
        for lane in [56.0, 60] {
            for width in [180.0, 340] {
                let (window, host) = rows(model, studio, laneHeight: lane, width: width)
                let label = "\(lane) pt lanes at \(width) pt"
                let out = outside(host, width: width)
                #expect(out.isEmpty, "inside the row: \(label): \(out)")
                // Row 2 records with no state: row 1 has no more text buttons than it.
                #expect(
                    bezels(host, lane: 0, laneHeight: lane) == bezels(host, lane: 1, laneHeight: lane),
                    "no \"Privacy…\" text button: \(label)")
                window.orderFront(nil)
                drawNow(window)
                try await Task.sleep(for: .milliseconds(200))
                let capture = try await TimelineColorTests.capture(window)
                let rect = host.convert(NSRect(x: 0, y: 0, width: width, height: lane), to: nil)
                let orange = try TimelineRulerTests.pixels(of: rect, capture, window).filter(Self.isOrange).count
                #expect(orange > 10, "the orange symbol shows: \(label)")
                window.close()
            }
        }
        await model.close()
    }
}
