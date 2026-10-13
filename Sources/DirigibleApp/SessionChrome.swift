import AppKit
import DirigibleCore
import Observation

/// The chrome of one session window (decision 0023): the toolbar and its delegate, and the item
/// states and the time from one observation loop. It belongs to the window, not to the content
/// controller, so a later split view changes no toolbar code.
@MainActor final class SessionChrome: NSObject, NSToolbarDelegate, NSMenuItemValidation {
    let toolbar = NSToolbar(identifier: ToolbarItemID.toolbar)
    /// The mark of a connected agent (C12): a title bar accessory, not a toolbar item, so the
    /// autosaved toolbar never changes. The chrome adds it while an agent is connected and removes
    /// it after: a trailing accessory ignores `isHidden`.
    let agentMark = agentMarkAccessory()
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
    /// The clock of the time limit. Tests give their own.
    var now: () -> ContinuousClock.Instant = { .now }
    /// Posts a VoiceOver announcement. Tests give their own.
    var announce: @MainActor (String, NSAccessibilityPriorityLevel) -> Void = postAnnouncement
    /// The record time left of the armed tracks before a take. It only returns a value;
    /// `refreshRecordTime()` writes it. Tests give their own.
    var readRecordTime: @MainActor ([TrackID]) async -> Duration?
    /// The one read that runs. A blocked `fstatfs` on a hung volume keeps its pool thread, so a
    /// trigger during a read starts no second read: it asks for one more read after it.
    private var reading: Task<Void, Never>?
    private var readAgain = false
    /// The reads that started and that ended, written or dropped, for the tests.
    private(set) var recordTimeReadsStarted = 0
    private(set) var recordTimeReads = 0
    /// The armed set and the idle state of the last read: a change reads again.
    private var readFor: (armed: [TrackID], idle: Bool)?
    /// Reads the record time again at an interval while idle.
    private var ticker: Task<Void, Never>?
    /// Runs a loop turn every 100 ms while a take records: no observed value carries the record head.
    private var headTick: Task<Void, Never>?

    init(model: SessionWindow, window: NSWindow) {
        self.model = model
        self.window = window
        readRecordTime = { [weak model] armed in await model?.idleStudio?.remainingRecordTime(armed: armed) }
        super.init()
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        // Icon only: 1180 pt fits the default set (ux-decisions 8). Set before the autosave, so a
        // saved user choice wins.
        toolbar.displayMode = .iconOnly
        toolbar.autosavesConfiguration = true
        window.toolbarStyle = .unified
        // A visible title keeps the display-mode menu (Icon and Text).
        window.titleVisibility = .visible
        window.toolbar = toolbar
        update()
        startTicker()
    }

    /// Reads the record time again every `interval` while idle, from now. The window starts it at
    /// open; a test that counts reads starts it again with a long interval, so no tick reads
    /// during the test.
    func startTicker(every interval: Duration = .seconds(10)) {
        ticker?.cancel()
        ticker = Task { [weak self] in
            // A cancel ends the sleep early: it reads nothing then.
            while (try? await Task.sleep(for: interval)) != nil {
                guard let self else { return }
                if self.model?.idleStudio != nil { self.refreshRecordTime() }
            }
        }
    }

    /// Ends the loop, the record-time read, and its timer. The window calls it at its close.
    func close() {
        closed = true
        ticker?.cancel()
        headTick?.cancel()
        reading?.cancel()
    }

    /// Reads the record time left of the armed tracks with a route, and writes it only when the
    /// armed set is the same (plan gate 1 item 4). One read runs at a time; the triggers during
    /// it give one more read after it (code gate 1 item 2). The window calls it at focus; the
    /// loop calls it at open, at an arm change, and after a take.
    func refreshRecordTime() {
        guard let model, !closed else { return }
        guard reading == nil else {
            readAgain = true
            return
        }
        let armed = model.armedWithRoute
        recordTimeReadsStarted += 1
        reading = Task { [weak self] in
            let left = armed.isEmpty ? nil : await self?.readRecordTime(armed)
            guard let self else { return }
            self.recordTimeReads += 1
            self.reading = nil
            if !self.closed, let model = self.model, model.armedWithRoute == armed, model.idleRecordTimeLeft != left {
                model.idleRecordTimeLeft = left
            }
            if self.readAgain {
                self.readAgain = false
                self.refreshRecordTime()
            }
        }
    }

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
        if model.canStop, headTick == nil {
            headTick = Task { [weak self] in
                while (try? await Task.sleep(for: .milliseconds(100))) != nil {
                    // The check and the clear are in one turn, so a new take always starts a new tick.
                    guard let self, self.model?.canStop == true else {
                        self?.headTick = nil
                        return
                    }
                    self.update()
                }
            }
        }
        let key = (armed: model.armedWithRoute, idle: model.idleStudio != nil)
        if readFor.map({ $0.armed != key.armed || $0.idle != key.idle }) ?? true {
            readFor = key
            if key.idle { refreshRecordTime() }
        }
    }

    /// Writes only what differs from the controls. Each push-on button is compared with its
    /// control state on every turn, because a click flips it before its action.
    private func apply(_ state: ChromeState) {
        turns += 1
        for item in toolbar.items { apply(state, to: item) }
        if let time, time.text != state.time {
            let now = now()
            if !state.playing || now - timeWritten >= .milliseconds(100) {
                time.text = state.time
                timeWritten = now
            }
        }
        if let window, window.subtitle != state.subtitle { window.subtitle = state.subtitle }
        // A hidden trailing accessory still draws (probe), so the mark is added and removed.
        if let window, window.titlebarAccessoryViewControllers.contains(agentMark) != state.agentConnected {
            if state.agentConnected {
                window.addTitlebarAccessoryViewController(agentMark)
            } else {
                agentMark.removeFromParent()
            }
        }
        guard let model, model.shown != state.shown else { return }
        // A banner of a kind that did not show is announced once.
        for banner in state.shown.banners where !model.shown.banners.contains(where: { $0.key == banner.key }) {
            if let priority = banner.announcement { announce(banner.text, priority) }
        }
        model.shown = state.shown
    }

    private func apply(_ state: ChromeState, to item: NSToolbarItem) {
        guard let id = ToolbarItemID(rawValue: item.itemIdentifier.rawValue), id != .time else { return }
        let enabled = state.enabled.contains(id)
        if item.isEnabled != enabled { item.isEnabled = enabled }
        guard let button = item.view as? NSButton else { return }
        if button.isEnabled != enabled { button.isEnabled = enabled }
        let value: NSControl.StateValue = state.on.contains(id) ? .on : .off
        if button.state != value { button.state = value }
        if let menuItem = item.menuFormRepresentation, menuItem.state != value { menuItem.state = value }
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
        item.possibleLabels = [id.label.text]
        item.paletteLabel = id.command?.menuItem.title.text ?? id.label.text
        if let command = id.command { item.toolTip = toolbarTooltip(command) }
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
        item.target = self
        item.action = #selector(runItem(_:))
        if id.isToggle {
            let button = Self.toggleButton(id)
            button.target = self
            button.action = #selector(runItem(_:))
            // One width for the push-on items: their symbols gave 40 to 51 pt (ui-polish-chrome U5).
            button.widthAnchor.constraint(equalToConstant: Self.toggleWidth).isActive = true
            item.view = button
            // AppKit gives the overflow menu item of a view item no state (probe P4).
            let menuItem = NSMenuItem(title: id.label.text, action: #selector(runItem(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.identifier = button.identifier
            item.menuFormRepresentation = menuItem
        } else {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: id.label.text)
            item.isBordered = true
        }
        if let model { apply(ChromeState(model: model), to: item) }
        return item
    }

    /// The button of a push-on item, with no target.
    private static func toggleButton(_ id: ToolbarItemID) -> NSButton {
        let image = id.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: id.label.text) }
        let button = NSButton(image: toggleImage(id, image), target: nil, action: nil)
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .toolbar
        button.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
        return button
    }

    /// The widest fitting width of the push-on items, computed once.
    private static let toggleWidth =
        ToolbarItemID.allCases.filter(\.isToggle)
        .map { toggleButton($0).fittingSize.width }.max() ?? 0

    /// Record keeps its red in the toolbar, the overflow menu, and the palette: a palette
    /// configuration makes the symbol a color image, not a template.
    private static func toggleImage(_ id: ToolbarItemID, _ image: NSImage?) -> NSImage {
        let image = image ?? NSImage()
        guard id == .record else { return image }
        return image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) ?? image
    }

    /// The overflow menu item of a push-on item is enabled when its toolbar item is.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let model, let raw = menuItem.identifier?.rawValue, let id = ToolbarItemID(rawValue: raw) else {
            return true
        }
        return ChromeState(model: model).enabled.contains(id)
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

/// Posts a VoiceOver announcement of the app.
@MainActor func postAnnouncement(_ text: String, priority: NSAccessibilityPriorityLevel) {
    NSAccessibility.post(
        element: NSApp as Any, notification: .announcementRequested,
        userInfo: [.announcement: text, .priority: priority.rawValue])
}
