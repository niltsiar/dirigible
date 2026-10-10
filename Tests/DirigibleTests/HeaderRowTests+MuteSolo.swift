import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Mute and solo C7 g (decision 0039): each row form shows M and S only from its measured width,
/// so the route, the lost-device symbol, and the dropped-frames symbol keep their room.
extension HeaderRowTests {
    /// The arm, M, and S boxes under `host`: SwiftUI shapes with hit views of 18 x 16 pt.
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
        // Every row is armed: the red arm boxes are left of the counted columns.
        model.armed = Set(studio.session.tracks.map(\.id))
        #expect((180...480).contains(TrackHeaders.muteSoloWidth), "one line: \(TrackHeaders.muteSoloWidth)")
        #expect(
            (180...480).contains(TrackHeaders.muteSoloTwoLineWidth), "two lines: \(TrackHeaders.muteSoloTwoLineWidth)")
        let forms = [(50.0, TrackHeaders.muteSoloWidth), (100.0, TrackHeaders.muteSoloTwoLineWidth)]
        for (lane, threshold) in forms {
            for width in [threshold, threshold - 1, 180] {
                let (window, host) = rows(model, studio, laneHeight: lane, width: width)
                let label = "\(lane) pt lanes at \(width) pt"
                #expect(
                    flagBoxes(host, in: host).count == (width >= threshold ? 9 : 3),
                    "arm in each row, M and S only from the gate: \(label)")
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
                    let columns = x ?? Self.rightOfArm...width
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

    /// True for the red of a fault symbol or of an armed box, over a light row.
    static func isRed(_ pixel: UInt32) -> Bool {
        let (r, g, b) = (pixel >> 16 & 0xFF, pixel >> 8 & 0xFF, pixel & 0xFF)
        return r > 180 && g < 90 && b < 90
    }

    /// The red pixels in the arm box of each row, top row first, in one-line rows at 340 pt.
    func armRed(_ model: SessionWindow, _ studio: Studio) async throws -> [Int] {
        let (window, host) = rows(model, studio, laneHeight: 50, width: 340)
        defer { window.close() }
        window.orderFront(nil)
        drawNow(window)
        try await Task.sleep(for: .milliseconds(200))
        let capture = try await TimelineColorTests.capture(window)
        let arms = flagBoxes(host, in: host).filter { $0.maxX < Self.rightOfArm }.sorted { $0.minY < $1.minY }
        return try arms.map { box in
            try TimelineRulerTests.pixels(of: host.convert(box, to: nil), capture, window).filter(Self.isRed).count
        }
    }

    /// The arm box is the first box of each row: red with t2 armed, and with no red with t1 not armed.
    @Test func theArmButtonIsRedOnlyWhenOn() async throws {
        let (model, studio) = try await model()
        model.armed = ["t2"]
        let red = try await armRed(model, studio)
        #expect(red.count == 2 && red[0] == 0 && red[1] > 20, "red pixels in the arm box of each row: \(red)")
        await model.close()
    }
}
