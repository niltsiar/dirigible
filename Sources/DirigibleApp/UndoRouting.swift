import AppKit

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

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let text = undoTarget(firstResponder: firstResponder) == .text
        switch menuItem.action {
        case #selector(undo(_:)): return text ? firstResponder?.undoManager?.canUndo == true : model?.canUndo == true
        case #selector(redo(_:)): return text ? firstResponder?.undoManager?.canRedo == true : model?.canRedo == true
        default: return super.validateMenuItem(menuItem)
        }
    }
}
