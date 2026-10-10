import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Mute and solo C7 g (decision 0039): each row form shows M and S only from its measured width,
/// and the Monitor box only from its own (record monitor run 1b, B11), so the route, the
/// lost-device symbol, and the dropped-frames symbol keep their room.
extension HeaderRowTests {
    /// The arm, Monitor, M, and S boxes under `host`: SwiftUI shapes with hit views of 18 x 16 pt.
    func flagBoxes(_ view: NSView, in host: NSView) -> [NSRect] {
        let frame = view.convert(view.bounds, to: host)
        let box =
            String(describing: type(of: view)).contains("ShapeHitTesting")
            && frame.size == NSSize(width: 18, height: 16)
        return (box ? [frame] : []) + view.subviews.flatMap { flagBoxes($0, in: host) }
    }

    /// The first header x right of the arm boxes under `host`: the smallest right edge of a box,
    /// plus 1 pt. A count of state colors starts here, so a red arm box does not count as a fault.
    func rightOfArm(_ host: NSView) throws -> Double {
        try #require(flagBoxes(host, in: host).map { Double($0.maxX) }.min(), "no arm box") + 1
    }

    /// The leaf views under `host` that go past the right padding of a row of `width`. A view of
    /// almost the row width is a row background, not a control.
    func outside(_ host: NSView, width: Double) -> [String] {
        func leaves(_ view: NSView) -> [NSView] { view.subviews.isEmpty ? [view] : view.subviews.flatMap(leaves) }
        return leaves(host).compactMap { leaf in
            let frame = leaf.convert(leaf.bounds, to: host)
            return frame.width < width - 20 && frame.maxX > width - 8 ? "\(type(of: leaf)) \(frame)" : nil
        }
    }

    @Test func muteAndSoloShowOnlyWhereTheyFit() async throws {
        let (model, studio) = try await model(tracks: 3)
        studio.liveTracks["t1"] = LiveTrack(state: .deviceLost, droppedFrames: 0, peak: 0)
        studio.liveTracks["t2"] = LiveTrack(
            state: .recording, droppedFrames: 3, peak: 0.1, shortTerm: LUFS(value: -17.4))
        // Every row is armed: the red arm boxes are left of the counted columns.
        model.armed = Set(studio.session.tracks.map(\.id))
        #expect((180...340).contains(TrackHeaders.muteSoloWidth), "B12, one line: \(TrackHeaders.muteSoloWidth)")
        #expect(
            (180...480).contains(TrackHeaders.muteSoloTwoLineWidth), "two lines: \(TrackHeaders.muteSoloTwoLineWidth)")
        let forms = [
            (50.0, TrackHeaders.muteSoloWidth, TrackHeaders.monitorWidth),
            (100.0, TrackHeaders.muteSoloTwoLineWidth, TrackHeaders.monitorTwoLineWidth),
        ]
        for (lane, threshold, monitor) in forms {
            #expect(monitor < threshold, "Monitor hides after M and S: \(lane) pt lanes")
            // Three rows: 4 boxes each from the M and S gate, 2 from the Monitor gate, else R only.
            let counts = [(threshold, 12), (threshold - 1, 6), (monitor, 6), (monitor - 1, 3), (180, 3)]
            for (width, expected) in counts where width >= 180 {
                let (window, host) = rows(model, studio, laneHeight: lane, width: width)
                let label = "\(lane) pt lanes at \(width) pt"
                let boxes = flagBoxes(host, in: host)
                #expect(boxes.count == expected, "R in each row, Monitor and M and S from their gates: \(label)")
                #expect(
                    boxes.allSatisfy { $0.minX >= 8 && $0.maxX <= width - 8 }, "the boxes are inside the row: \(label)")
                // At 180 pt a two-line row cuts its state text with no M and S too; the captures
                // check that width.
                if width > 180 {
                    let out = outside(host, width: width)
                    #expect(out.isEmpty, "inside the row: \(label): \(out)")
                }
                window.orderFront(nil)
                drawNow(window)
                try await Task.sleep(for: .milliseconds(200))
                let capture = try await TimelineColorTests.capture(window)
                let rightOfArm = try rightOfArm(host)
                func count(_ row: Int, x: ClosedRange<Double>? = nil, _ color: (UInt32) -> Bool) throws -> Int {
                    let columns = x ?? rightOfArm...width
                    let rect = host.convert(
                        NSRect(
                            x: columns.lowerBound, y: Double(row) * lane,
                            width: columns.upperBound - columns.lowerBound, height: lane),
                        to: nil)
                    return try TimelineRulerTests.pixels(of: rect, capture, window).filter(color).count
                }
                let (red, orange) = (Self.isRed, Self.isOrange)
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

    /// True for the orange of the dropped-frames symbol, over a light row.
    static func isOrange(_ pixel: UInt32) -> Bool {
        let (r, g, b) = (pixel >> 16 & 0xFF, pixel >> 8 & 0xFF, pixel & 0xFF)
        return r > 200 && g > 90 && g < 190 && b < 80
    }

    /// The red pixels in the arm box of each row, top row first, in one-line rows at 340 pt.
    func armRed(_ model: SessionWindow, _ studio: Studio) async throws -> [Int] {
        let (window, host) = rows(model, studio, laneHeight: 50, width: 340)
        defer { window.close() }
        window.orderFront(nil)
        drawNow(window)
        try await Task.sleep(for: .milliseconds(200))
        let capture = try await TimelineColorTests.capture(window)
        let rightOfArm = try rightOfArm(host)
        let arms = flagBoxes(host, in: host).filter { $0.maxX < rightOfArm }.sorted { $0.minY < $1.minY }
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

    /// During a take the buttons are disabled: the armed box of t2 keeps its full red, and the box
    /// of t1, not armed, stays with no red. A dimmed red (about 255, 177, 173) is not red.
    @Test func anOnButtonKeepsFullOpacityDuringATake() async throws {
        let (model, studio) = try await model()
        model.armed = ["t2"]
        studio.transport = .recording(take: 1)
        try #require(!model.canEdit, "the take disables the buttons")
        let red = try await armRed(model, studio)
        #expect(red.count == 2 && red[0] == 0 && red[1] > 20, "red pixels in the arm box of each row: \(red)")
        studio.transport = .idle
        await model.close()
    }
}
