import AppKit
import SwiftUI

/// The tooltip of a toolbar item: the menu text and the key, "Record (⌘R)". The zoom items also
/// name the gestures that zoom at the pointer (run 2026-10-11-ui-polish-header C21), and Record
/// names Record with Pre-roll and its key (decision 0070). `format` is the value of
/// `tooltipKey(command)` in the app language, and `text` gives the value of a key.
func toolbarTooltip(_ command: WindowCommand, format: String? = nil, text: (L10n) -> String = { $0.text }) -> String {
    let (title, key) = command.menuItem
    var arguments: [any CVarArg] = [text(title), keyText(key)]
    if command == .record {
        let preRoll = WindowCommand.recordPreRoll.menuItem
        arguments += [text(preRoll.title), keyText(preRoll.key)]
    }
    return String(format: format ?? text(tooltipKey(command)), locale: .current, arguments: arguments)
}

/// The tooltip and the accessibility label of the Sidebar item: "Hide Sidebar" while the leading pane
/// shows, else "Show Sidebar". It names no segment and no key: the item shows the last segment (C19).
func indexTooltip(shown: Bool, text: (L10n) -> String = { $0.text }) -> String {
    text(shown ? .toolbarSidebarHide : .toolbarSidebarShow)
}

/// Gives the Index item and its button the tooltip and the accessibility label of the state.
@MainActor func showIndexTooltip(on item: NSToolbarItem, _ button: NSButton, shown: Bool) {
    let tip = indexTooltip(shown: shown)
    if item.toolTip != tip { item.toolTip = tip }
    if button.accessibilityLabel() != tip { button.setAccessibilityLabel(tip) }
}

/// The key of the tooltip format of `command`.
func tooltipKey(_ command: WindowCommand) -> L10n {
    if command == .record { return .toolbarTooltipRecord }
    return [.timeline(.zoomIn), .timeline(.zoomOut)].contains(command) ? .toolbarTooltipZoom : .toolbarTooltip
}

/// A key as a menu shows it: the modifier glyphs, then the key ("⌥⌘N", "⌘.", "⌫").
func keyText(_ shortcut: KeyboardShortcut) -> String {
    let glyphs: [(EventModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
    let modifiers = glyphs.filter { shortcut.modifiers.contains($0.0) }.map(\.1).joined()
    let key: String =
        switch shortcut.key {
        case .space: L10n.keySpace.text
        case .delete: "⌫"
        case .return: "↩"
        case .home: "↖"
        case .end: "↘"
        default: String(shortcut.key.character).uppercased()
        }
    return modifiers + key
}
