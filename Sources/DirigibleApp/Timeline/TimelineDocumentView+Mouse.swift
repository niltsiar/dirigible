import AppKit
import DirigibleTimeline

extension TimelineDocumentView {
    // MARK: Mouse

    private func place(_ event: NSEvent) -> Place {
        let point = convert(event.locationInWindow, from: nil)
        return .lanes(x: Double(point.x), y: Double(point.y))
    }

    /// The lane menu (decision 0037). AppKit asks for it at a right-click and a Control-click.
    override func menu(for event: NSEvent) -> NSMenu? { scrollView?.laneMenu(at: place(event)) }

    override func mouseDown(with event: NSEvent) {
        // A Control-click opens the menu and starts no press (`ui-panel.md` 5).
        guard !event.modifierFlags.contains(.control) else { return }
        window?.makeFirstResponder(self)
        let flags = event.modifierFlags
        commandHeld = flags.contains(.command)
        scrollView?.mouse(
            .down(
                place(event), shift: flags.contains(.shift), command: flags.contains(.command),
                option: flags.contains(.option), clicks: event.clickCount))
        showCursor(event)
    }

    override func mouseDragged(with event: NSEvent) {
        commandHeld = event.modifierFlags.contains(.command)
        scrollView?.mouse(.drag(place(event)))
        scrollView?.dragPointer = (event.locationInWindow, ruler: false)
        showCursor(event)
    }

    override func mouseUp(with event: NSEvent) {
        scrollView?.mouse(.up(place(event)))
        showCursor(event)
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // The help tag of the view adds a tracking area of its own.
        guard !trackingAreas.contains(where: { $0.owner === self && $0.options.contains(.mouseMoved) }) else { return }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { showCursor(event) }
    override func cursorUpdate(with event: NSEvent) { showCursor(event) }

    /// A key-down or key-up of Option, Shift, or Command sets the cursor again at the last point,
    /// with no mouse move.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if let hoverPlace { showCursor(at: hoverPlace, flags: event.modifierFlags) }
        // A Command change during a drag turns snap off or on at once, with no mouse move.
        let command = event.modifierFlags.contains(.command)
        if command != commandHeld {
            commandHeld = command
            scrollView?.resendDrag()
        }
    }

    private func showCursor(_ event: NSEvent) {
        showCursor(at: place(event), flags: modifierFlags())
    }

    private func showCursor(at place: Place, flags: NSEvent.ModifierFlags) {
        hoverPlace = place
        guard let kind = scrollView?.cursor(at: place, flags: flags) else { return }
        shownCursor = kind
        NSCursor.timeline(kind).set()
    }
}
