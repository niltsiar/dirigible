import AppKit

extension NSWindow {
    /// The first frame of a session window: a content size of min(1180 pt, the visible screen
    /// width) x 720 pt, cascaded from `previous` (right and down), else centered.
    func placeAsSessionWindow(after previous: NSWindow?) {
        let width = min(1180, (screen ?? NSScreen.main)?.visibleFrame.width ?? 1180)
        setContentSize(NSSize(width: width, height: 720))
        guard let previous else {
            center()
            return
        }
        // The first call puts the window at the top left of `previous` and gives the next point.
        cascadeTopLeft(from: cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
    }
}
