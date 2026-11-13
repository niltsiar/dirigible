import AppKit

@testable import DirigibleApp

extension NSTableView {
    /// The row elements that the table gives to an accessibility client: not the row views. The
    /// other children are the columns and the header view.
    var clientRows: [Any] { (accessibilityChildren() ?? []).filter { !($0 is NSTableColumn || $0 is NSView) } }

    /// The custom actions that an accessibility client reads on row `n`.
    func clientActions(row n: Int) -> [NSAccessibilityCustomAction] {
        let rows = clientRows
        guard rows.indices.contains(n) else { return [] }
        let value = (rows[n] as AnyObject).perform(NSSelectorFromString("accessibilityCustomActions"))
        return value?.takeUnretainedValue() as? [NSAccessibilityCustomAction] ?? []
    }

    func clientAction(row n: Int, _ name: L10n) -> NSAccessibilityCustomAction? {
        clientActions(row: n).first { $0.name == name.text }
    }

    /// The label that VoiceOver reads for row `n`: the label of its name cell.
    func spokenLabel(row n: Int) -> String? {
        let cell = view(atColumn: column(withIdentifier: SessionIndexTable.nameColumn), row: n, makeIfNecessary: false)
        return cell?.isAccessibilityElement() == true ? cell?.accessibilityLabel() : nil
    }
}

extension NSAccessibilityCustomAction {
    /// Runs the action as an accessibility client does: by its handler, or by its target and selector.
    func perform() {
        if let handler {
            _ = handler()
        } else {
            _ = (target as AnyObject?)?.perform(selector, with: self)
        }
    }
}
