import AppKit
import DirigibleTimeline

enum UndoTarget: Equatable {
    /// The typing in a focused text field. The `UndoManager` of the field editor has it: a
    /// SwiftUI text field gives the editor one that is not the window `UndoManager`.
    case text
    /// A session edit: `Studio` keeps the history.
    case session
}

/// A focused text field makes the field editor (an `NSText`) the first responder.
func undoTarget(firstResponder: NSResponder?) -> UndoTarget { firstResponder is NSText ? .text : .session }

/// The session window. The default Undo and Redo items send `undo:` and `redo:` along the
/// responder chain (P12), and the window is on that chain also when it is the first responder
/// itself. The Studio history never enters an `UndoManager`, so a text undo and a session undo
/// cannot mix.
final class UndoRoutingWindow: NSWindow {
    weak var model: SessionWindow?

    @objc func undo(_ sender: Any?) {
        switch undoTarget(firstResponder: firstResponder) {
        case .text: firstResponder?.undoManager?.undo()
        case .session: model?.undo()
        }
    }

    @objc func redo(_ sender: Any?) {
        switch undoTarget(firstResponder: firstResponder) {
        case .text: firstResponder?.undoManager?.redo()
        case .session: model?.redo()
        }
    }

    /// Select All with no text focused: the whole session on every track (decision 0017). A focused
    /// text field takes `selectAll:` before the window on the responder chain.
    @objc override func selectAll(_ sender: Any?) {
        model?.run(.selectAll)
    }

    /// Cut, Copy, Paste, and Delete with no text focused (decision 0018). A focused text field
    /// takes these selectors before the window on the responder chain (probe E3).
    @objc func cut(_ sender: Any?) { model?.run(.cut) }
    @objc func copy(_ sender: Any?) { model?.run(.copy) }
    @objc func paste(_ sender: Any?) { model?.run(.paste) }
    @objc func delete(_ sender: Any?) { model?.run(.delete) }

    /// Esc (decision 0017): with no text focused, the Marks empty. During a timeline gesture, Esc
    /// ends only the gesture (decision 0020), in order: a header drag, an overview drag (0025), a
    /// lane gesture. There is no Esc menu item, so alerts and sheets keep
    /// the key.
    override func cancelOperation(_ sender: Any?) {
        switch undoTarget(firstResponder: firstResponder) {
        case .text: super.cancelOperation(sender)
        case .session:
            if model?.timelineView?.headers.cancelDrag() == true { return }
            if model?.timelineView?.cancelOverview() == true { return }
            if model?.timelineView?.cancelGesture() == true { return }
            model?.run(.deselectAll)
        }
    }

    /// Command-= zooms in as Command-plus does (U1): on a US keyboard the item of Command-"+"
    /// needs Shift (probe K1). The Spanish Shift-0 gives "=" too, so an "=" with Shift does not zoom.
    /// Only the four modifier keys count: Caps Lock and the keypad flag do not change the key.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.charactersIgnoringModifiers == String(MenuKeys.zoomInEquals.key.character),
            event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command, let model
        {
            model.run(TimelineCommand.zoomIn)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let text = undoTarget(firstResponder: firstResponder) == .text
        switch menuItem.action {
        case #selector(undo(_:)): return text ? firstResponder?.undoManager?.canUndo == true : model?.canUndo == true
        case #selector(redo(_:)): return text ? firstResponder?.undoManager?.canRedo == true : model?.canRedo == true
        default: return super.validateMenuItem(menuItem)
        }
    }
}

/// True when a plain transport key acts: the key window is a session window, and its first
/// responder is not text (decision 0016, plan gate 1 item 4).
@MainActor func takesTransportKeys(_ keyWindow: NSWindow?) -> Bool {
    keyWindow is UndoRoutingWindow && undoTarget(firstResponder: keyWindow?.firstResponder) == .session
}

/// A plain-key menu item takes its key also when it is disabled (probe K1). So each plain-key
/// action first calls this. When the key window does not take transport keys (a panel, an
/// alert, a focused text field), it gives the key-down to the first responder of that window,
/// which inserts it (probe K3), and returns true. With no key window, it returns false.
///
/// When no responder uses the key (an alert whose OK has the cancel role), `NSWindow.keyDown`
/// routes it back to the menu item of the key, which calls this again. That call returns true and
/// forwards nothing, so the key ends there (run 2026-10-05-alert-return-hang).
@MainActor func forwardTypingKey(_ event: NSEvent, in keyWindow: NSWindow?) -> Bool {
    guard event.type == .keyDown, let keyWindow, !takesTransportKeys(keyWindow) else { return false }
    guard !forwardingKey else { return true }
    forwardingKey = true
    defer { forwardingKey = false }
    (keyWindow.firstResponder ?? keyWindow).keyDown(with: event)
    return true
}

/// True while `forwardTypingKey` gives a key-down to a window.
@MainActor private var forwardingKey = false
