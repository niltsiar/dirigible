import AppKit
import DirigibleTimeline
import Testing

@testable import DirigibleApp

/// The window point of box `index` of header row `row`: 0 arm, 1 Monitor, 2 M, 3 S.
@MainActor func headerBoxPoint(_ index: Int, row: Int, in view: TimelineScrollView) throws -> NSPoint {
    let rows = try headerBoxRows(in: view)
    try #require(rows.count > row && rows[row].count > index, "box \(index) in row \(row): \(rows)")
    let frame = rows[row][index]
    return NSPoint(x: frame.midX, y: frame.midY)
}

/// The window frames of the header boxes. The boxes are SwiftUI shapes: the hit views of 18 x 16
/// pt in the header, grouped by row, top row first, left to right.
@MainActor func headerBoxRows(in view: TimelineScrollView) throws -> [[NSRect]] {
    let window = try #require(view.window)
    window.contentView?.layoutSubtreeIfNeeded()
    drawNow(window)
    func boxes(_ view: NSView) -> [NSRect] {
        let frame = view.convert(view.bounds, to: nil)
        let box =
            String(describing: type(of: view)).contains("ShapeHitTesting")
            && frame.size == NSSize(width: 18, height: 16)
        return (box ? [frame] : []) + view.subviews.flatMap(boxes)
    }
    return Dictionary(grouping: boxes(view.headers.host)) { $0.midY.rounded() }
        .sorted { $0.key > $1.key }.map { $0.value.sorted { $0.minX < $1.minX } }
}

/// A click at `point` of `window`: the down and the up go to the hit view of the frame view, as
/// `NSWindow.sendEvent` sends them in a key window.
@MainActor func clickPoint(_ point: NSPoint, in window: NSWindow, flags: NSEvent.ModifierFlags = []) throws {
    drawNow(window)
    let hit = try #require(window.contentView?.superview?.hitTest(point))
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = try #require(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        if type == .leftMouseDown { hit.mouseDown(with: event) } else { hit.mouseUp(with: event) }
    }
    drawNow(window)
}
