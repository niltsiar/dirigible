import AppKit

/// The chrome of one session window (decision 0023): the toolbar and its delegate. It belongs to
/// the window, not to the content controller, so a later split view changes no toolbar code.
@MainActor final class SessionChrome: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: ToolbarItemID.toolbar)
    private weak var model: SessionWindow?
    private(set) weak var window: NSWindow?

    init(model: SessionWindow, window: NSWindow) {
        self.model = model
        self.window = window
        super.init()
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbarStyle = .unified
        // A visible title keeps the display-mode menu (Icon and Text).
        window.titleVisibility = .visible
        window.toolbar = toolbar
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ToolbarItemID.defaults }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ToolbarItemID.allCases.map(\.identifier) + [.space, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let id = ToolbarItemID(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = id.label.text
        item.paletteLabel = id.command?.title.text ?? id.label.text
        item.visibilityPriority = id.priority
        // The chrome sets the states from the window state; validation runs only after events.
        item.autovalidates = false
        guard let symbol = id.symbol else {
            item.view = TimeDisplay()
            return item
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: id.label.text)
        item.target = self
        item.action = #selector(perform(_:))
        if id.isToggle {
            let button = NSButton(image: toggleImage(id, image), target: self, action: #selector(perform(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .toolbar
            button.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
            item.view = button
        } else {
            item.image = image
            item.isBordered = true
        }
        return item
    }

    /// Record keeps its red in the toolbar, the overflow menu, and the palette: a palette
    /// configuration makes the symbol a color image, not a template.
    private func toggleImage(_ id: ToolbarItemID, _ image: NSImage?) -> NSImage {
        let image = image ?? NSImage()
        guard id == .record else { return image }
        return image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) ?? image
    }

    /// The action of each item: a toolbar item, its view, or its overflow menu item.
    @objc func perform(_ sender: Any?) {
        let raw =
            (sender as? NSToolbarItem)?.itemIdentifier.rawValue
            ?? (sender as? NSUserInterfaceItemIdentification)?.identifier?.rawValue
        guard let model, let raw, let command = ToolbarItemID(rawValue: raw)?.command else { return }
        if let selector = command.selector, let window {
            // As the menu item: from the first responder, so a focused text field takes it first.
            _ = (window.firstResponder ?? window).tryToPerform(selector, with: nil)
            return
        }
        model.run(command)
    }
}

/// The playhead time in the toolbar: a fixed box from the font, so the toolbar never moves when
/// the digits change.
final class TimeDisplay: NSView {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.labelColor,
    ]

    var text = "0:00:00.000" {
        didSet { if text != oldValue { needsDisplay = true } }
    }

    override var intrinsicContentSize: NSSize {
        let size = ("00:00:00.000" as NSString).size(withAttributes: Self.attributes)
        return NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = (text as NSString).size(withAttributes: Self.attributes).height
        (text as NSString).draw(at: NSPoint(x: 0, y: (bounds.height - height) / 2), withAttributes: Self.attributes)
    }
}

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
