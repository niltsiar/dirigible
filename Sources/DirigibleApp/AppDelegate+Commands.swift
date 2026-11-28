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

    /// With the focus in the Transcript pane, the Shift-Left and Shift-Right keys of Previous Clip
    /// and Next Clip move the end of the pane selection (P8).
    func transport(_ command: TransportCommand, event: NSEvent?, in keyWindow: NSWindow?) {
        if let event, forwardTypingKey(event, in: keyWindow) { return }
        if event?.type == .keyDown, let pane = keyWindow?.firstResponder as? TranscriptTextView,
            case .seek(let seek) = command, seek == .previousClip || seek == .nextClip
        {
            return pane.moveSelectionEnd(by: seek == .nextClip ? 1 : -1)
        }
        key?.transport(command)
    }

    /// The action of Record > Record with Pre-roll (decision 0070): a key that belongs to text or to a
    /// panel goes there, as the transport keys do. A held P starts one take.
    func recordPreRoll() {
        recordPreRoll(event: NSApp.currentEvent, in: NSApp.keyWindow)
    }

    func recordPreRoll(event: NSEvent?, in keyWindow: NSWindow?) {
        if let event, forwardTypingKey(event, in: keyWindow) { return }
        if let event, event.type == .keyDown, event.isARepeat { return }
        key?.run(.recordPreRoll)
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
        // The menu key equivalents of Return and Delete come before the list sees the key.
        if command == .renameTrack || command == .delete, event?.type == .keyDown, let model = key,
            model.silenceListHasFocus(in: keyWindow)
        {
            return model.silenceListKey(command)
        }
        // A held Command-Return marks once, as a held N toggles once.
        if command == .addMarker || command == .addChapter, let event, event.type == .keyDown, event.isARepeat {
            return
        }
        // The list gets the keys of its rows. A menu click acts as its key, except Return, Shift-Return,
        // Add Marker, and Add Chapter.
        if let model = key, model.indexListHasFocus(in: keyWindow) {
            // Delete selects the next row, so a held Delete removes one selection, not row after row.
            if command == .delete, let event, event.type == .keyDown, event.isARepeat { return }
            if model.indexCommand(command, isKey: event?.type == .keyDown) { return }
        }
        // The Bins list gets the keys of its items, as the index list (C23). A held key edits one item.
        if let model = key, model.binsListHasFocus(in: keyWindow) {
            if command.binsFocus == .item, let event, event.type == .keyDown, event.isARepeat { return }
            if model.binsCommand(command, isKey: event?.type == .keyDown) { return }
        }
        if command.forwardsKey, let event, forwardTypingKey(event, in: keyWindow) { return }
        // A held Shift-D ducks once. The guard sits after the forward, so a held key in a field still types.
        if command == .duckSelection, let event, event.type == .keyDown, event.isARepeat { return }
        if let selector = command.selector {
            if let keyWindow { _ = (keyWindow.firstResponder ?? keyWindow).tryToPerform(selector, with: nil) }
            return
        }
        // Return in a header of the Transcript pane seeks. A click on the menu item is no key press.
        if command == .renameTrack, event?.type == .keyDown, key?.transcriptFollow.pane?.returnInHeader() == true {
            return
        }
        key?.run(command)
    }
}

extension AppDelegate {
    /// The items that a field gives a key to, and that are still off when no session window is key.
    private static let needsWindow: Set<TimelineCommand> = [.addMarker, .addChapter, .replace, .fill, .duplicate]

    /// File > Remove Unused Files… is on while the key session window takes an edit (decision 0047).
    /// Also the state of the archive item, Archive Session... or Unarchive Session (decision 0072).
    var canRemoveUnusedFiles: Bool { key?.canEdit == true }

    /// The state of a timeline menu item (`SessionWindow.isOn`). With no key session window (a sheet
    /// of the window, the Settings window, or the start window is key), only the items whose key a
    /// field uses (0018 K1) and the items that send a selector stay on. Add Marker and Add Chapter
    /// are off, because their key adds no marker then (F107 C9d); so are Replace, Paste to Fill
    /// Selection, and Duplicate, which need a range or a clip set of a window.
    func isOn(_ command: TimelineCommand) -> Bool {
        guard let key else {
            return command.selector != nil || (command.forwardsKey && !Self.needsWindow.contains(command))
        }
        return key.isOn(command)
    }
}
