import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Mute and solo C7 g (decision 0039): each row form shows M and S only from its measured width,
/// so the route, the lost-device symbol, and the dropped-frames symbol keep their room.
extension HeaderRowTests {
    /// The M and S boxes under `host`: SwiftUI shapes with hit views of 18 x 16 pt.
    func flagBoxes(_ view: NSView, in host: NSView) -> [NSRect] {
        let frame = view.convert(view.bounds, to: host)
        let box =
            String(describing: type(of: view)).contains("ShapeHitTesting")
            && frame.size == NSSize(width: 18, height: 16)
        return (box ? [frame] : []) + view.subviews.flatMap { flagBoxes($0, in: host) }
    }

    @Test func muteAndSoloShowOnlyWhereTheyFit() async throws {
        let (model, studio) = try await model(tracks: 3)
        studio.liveTracks["t1"] = LiveTrack(state: .deviceLost, droppedFrames: 0, peak: 0)
        studio.liveTracks["t2"] = LiveTrack(
            state: .recording, droppedFrames: 3, peak: 0.1, shortTerm: LUFS(value: -17.4))
        #expect((180...480).contains(TrackHeaders.muteSoloWidth), "one line: \(TrackHeaders.muteSoloWidth)")
        #expect(
            (180...480).contains(TrackHeaders.muteSoloTwoLineWidth), "two lines: \(TrackHeaders.muteSoloTwoLineWidth)")
        let forms = [(50.0, TrackHeaders.muteSoloWidth), (100.0, TrackHeaders.muteSoloTwoLineWidth)]
        for (lane, threshold) in forms {
            for width in [threshold, threshold - 1, 180] {
                let (window, host) = rows(model, studio, laneHeight: lane, width: width)
                let label = "\(lane) pt lanes at \(width) pt"
                #expect(
                    flagBoxes(host, in: host).count == (width >= threshold ? 6 : 0), "M and S in each row: \(label)")
                func leaves(_ view: NSView) -> [NSView] {
                    view.subviews.isEmpty ? [view] : view.subviews.flatMap(leaves)
                }
                // At 180 pt a two-line row cuts its state text with no M and S too; the captures
                // check that width.
                for leaf in leaves(host) where width > 180 {
                    let frame = leaf.convert(leaf.bounds, to: host)
                    guard frame.width < width - 20 else { continue }
                    #expect(frame.maxX <= width - 8, "inside the row: \(label): \(type(of: leaf)) \(frame)")
                }
                window.orderFront(nil)
                drawNow(window)
                try await Task.sleep(for: .milliseconds(200))
                let capture = try await TimelineColorTests.capture(window)
                func count(_ row: Int, x: ClosedRange<Double>? = nil, _ color: (UInt32, UInt32, UInt32) -> Bool) throws
                    -> Int
                {
                    let columns = x ?? 0...width
                    let rect = host.convert(
                        NSRect(
                            x: columns.lowerBound, y: Double(row) * lane,
                            width: columns.upperBound - columns.lowerBound, height: lane),
                        to: nil)
                    return try TimelineRulerTests.pixels(of: rect, capture, window).filter { pixel in
                        color(pixel >> 16 & 0xFF, pixel >> 8 & 0xFF, pixel & 0xFF)
                    }.count
                }
                let red = { (r: UInt32, g: UInt32, b: UInt32) in r > 180 && g < 90 && b < 90 }
                let orange = { (r: UInt32, g: UInt32, b: UInt32) in r > 200 && g > 90 && g < 190 && b < 80 }
                #expect(try count(0, red) > 10, "the lost-device state shows: \(label)")
                #expect(try count(0, x: (width - 6)...width, red) == 0, "no state in the handle strip: \(label)")
                #expect(try count(1, orange) > 10, "the dropped-frames state shows: \(label)")
                #expect(try count(1, x: (width - 6)...width, orange) == 0, "no dropped frames in the strip: \(label)")
                window.close()
            }
        }
        await model.close()
    }
}
