import AppKit
import Observation

/// The chrome of one session window (decision 0023): the toolbar and its delegate, and the item
/// states and the time from one observation loop. It belongs to the window, not to the content
/// controller, so a later split view changes no toolbar code.
@MainActor final class SessionChrome: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: ToolbarItemID.toolbar)
    private weak var model: SessionWindow?
    private(set) weak var window: NSWindow?
    private(set) weak var time: TimeDisplay?
    /// The loop turns, for the tests.
    private(set) var turns = 0
    /// True while an observation waits for a change: a direct `update()` then arms no second one.
    private var tracking = false
    private var closed = false
    /// The last time write during a play: at most 10 changes a second, also at 2x.
    private var timeWritten = ContinuousClock.now - .seconds(1)

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
        update()
    }

    /// Ends the loop. The window calls it at its close.
    func close() { closed = true }

    /// One loop turn: derives the state, applies it, and arms the observation once.
    func update() {
        guard let model, !closed else { return }
        let state: ChromeState
        if tracking {
            state = ChromeState(model: model)
        } else {
            tracking = true
            state = withObservationTracking {
                ChromeState(model: model)
            } onChange: { [weak self] in
                Task { @MainActor in
                    self?.tracking = false
                    self?.update()
                }
            }
        }
        apply(state)
    }

    /// Writes only what differs from the controls. Each push-on button is compared with its
    /// control state on every turn, because a click flips it before its action.
    private func apply(_ state: ChromeState) {
        turns += 1
        for item in toolbar.items { apply(state, to: item) }
        if let time, time.text != state.time {
            let now = ContinuousClock.now
            if !state.playing || now - timeWritten >= .milliseconds(100) {
                time.text = state.time
                timeWritten = now
            }
        }
        if let model, model.shown != state.shown { model.shown = state.shown }
    }

    private func apply(_ state: ChromeState, to item: NSToolbarItem) {
        guard let id = ToolbarItemID(rawValue: item.itemIdentifier.rawValue), id != .time else { return }
        let enabled = state.enabled.contains(id)
        if item.isEnabled != enabled { item.isEnabled = enabled }
        guard let button = item.view as? NSButton else { return }
        if button.isEnabled != enabled { button.isEnabled = enabled }
        let value: NSControl.StateValue = state.on.contains(id) ? .on : .off
        if button.state != value { button.state = value }
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
            let display = TimeDisplay()
            if flag {
                time = display
                if let model { display.text = ChromeState(model: model).time }
            }
            item.view = display
            return item
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: id.label.text)
        item.target = self
        item.action = #selector(runItem(_:))
        if id.isToggle {
            let button = NSButton(image: toggleImage(id, image), target: self, action: #selector(runItem(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .toolbar
            button.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
            item.view = button
        } else {
            item.image = image
            item.isBordered = true
        }
        if let model { apply(ChromeState(model: model), to: item) }
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
    @objc func runItem(_ sender: Any?) {
        let raw =
            (sender as? NSToolbarItem)?.itemIdentifier.rawValue
            ?? (sender as? NSUserInterfaceItemIdentification)?.identifier?.rawValue
        guard let model, let raw, let id = ToolbarItemID(rawValue: raw), let command = id.command else { return }
        // A push-on button flips at the click, before this action: it shows the window state
        // again, so a refused Record is not lit (plan gate 1 item 1).
        if let button = sender as? NSButton { button.state = ChromeState(model: model).on.contains(id) ? .on : .off }
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

    /// The text changes, for the tests.
    private(set) var textChanges = 0
    var text = "0:00:00.000" {
        didSet {
            guard text != oldValue else { return }
            textChanges += 1
            needsDisplay = true
        }
    }

    // VoiceOver reads "Playhead" and the time. A play posts no notice for each change.
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
