import AppKit
import DirigibleAudio

/// The menu and key actions that reach the key session window (decisions 0016, 0017).
extension AppDelegate {
    // MARK: Transport

    /// The action of each plain-key Transport item: a key that belongs to text or to a panel
    /// goes there (probes K1, K3); else the key session window performs the command.
    func transport(_ command: TransportCommand) {
        transport(command, event: NSApp.currentEvent, in: NSApp.keyWindow)
    }

    func transport(_ command: TransportCommand, event: NSEvent?, in keyWindow: NSWindow?) {
        if let event, forwardTypingKey(event, in: keyWindow) { return }
        key?.transport(command)
    }

    /// The action of each plain-key item of Transport > Playback Speed: a key that belongs to text
    /// or to a panel goes there, as the transport keys do (decision 0052).
    func speed(_ change: SpeedChange) {
        speed(change, event: NSApp.currentEvent, in: NSApp.keyWindow)
    }

    func speed(_ change: SpeedChange, event: NSEvent?, in keyWindow: NSWindow?) {
        if let event, forwardTypingKey(event, in: keyWindow) { return }
        // A held Period toggles once, as N does; a held ">" or "<" steps at each repeat.
        if change == .toggle, let event, event.type == .keyDown, event.isARepeat { return }
        key?.speed(change)
    }

    /// The one writer of the snap preference: View > Snap, its N key, and the toolbar item. N goes
    /// to text or to a panel first, as the transport keys do.
    func toggleSnap() {
        toggleSnap(event: NSApp.currentEvent, in: NSApp.keyWindow)
    }

    func toggleSnap(event: NSEvent?, in keyWindow: NSWindow?) {
        if let event, forwardTypingKey(event, in: keyWindow) { return }
        // A held N toggles once, not at each key repeat.
        if let event, event.type == .keyDown, event.isARepeat { return }
        snaps.toggle()
        // A drag takes the new state at once, with no mouse move, as at a Command change.
        key?.timelineView?.resendDrag()
    }

    /// The action of each timeline menu item. A key that a text field uses (H, I, O, Backspace,
    /// Command-B, Command-arrows) goes to text or to a panel first, as the transport keys do (probes
    /// K1, K3, E4b, E5). An item of the Edit group sends its selector from the first responder of
    /// the key window (probes E2, E3).
    func timeline(_ command: TimelineCommand) {
        timeline(command, event: NSApp.currentEvent, in: NSApp.keyWindow)
    }

    func timeline(_ command: TimelineCommand, event: NSEvent?, in keyWindow: NSWindow?) {
        if command.forwardsKey, let event, forwardTypingKey(event, in: keyWindow) { return }
        if let selector = command.selector {
            if let keyWindow { _ = (keyWindow.firstResponder ?? keyWindow).tryToPerform(selector, with: nil) }
            return
        }
        // A held Command-Return marks once, as a held N toggles once.
        if command == .addMarker || command == .addChapter, let event, event.type == .keyDown, event.isARepeat {
            return
        }
        key?.run(command)
    }
}

extension AppDelegate {
    /// File > Remove Unused Files… is on while the key session window takes an edit (decision 0047).
    var canRemoveUnusedFiles: Bool { key?.canEdit == true }

    /// The state of a timeline menu item: the rule of the key session window (`SessionWindow.isOn`).
    /// With no key session window, Add Marker and Add Chapter are off: their key goes to the key
    /// window and no session gets a marker (F107 C9d). The other items stay on, as a field uses
    /// their keys (0018 K1).
    func isOn(_ command: TimelineCommand) -> Bool {
        guard let key else { return command != .addMarker && command != .addChapter }
        return key.isOn(command)
    }
}
