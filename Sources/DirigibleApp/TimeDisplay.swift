import AppKit

/// The playhead time in the toolbar: a fixed box from the font, so the toolbar never moves when
/// the digits change.
final class TimeDisplay: NSView {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.labelColor,
    ]

    /// The text changes, for the tests.
    private(set) var textChanges = 0
    var text = "0:00:00.000" {
        didSet {
            guard text != oldValue else { return }
            textChanges += 1
            needsDisplay = true
        }
    }

    // VoiceOver reads "Playhead" and the time. A play or a take posts no notice for each change.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { L10n.toolbarTime.text }
    override func accessibilityValue() -> Any? { text }

    override var intrinsicContentSize: NSSize {
        let size = ("00:00:00.000" as NSString).size(withAttributes: Self.attributes)
        return NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = (text as NSString).size(withAttributes: Self.attributes).height
        (text as NSString).draw(at: NSPoint(x: 0, y: (bounds.height - height) / 2), withAttributes: Self.attributes)
    }
}
