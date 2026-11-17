import AppKit

/// The look of a header row: the selection colors of a macOS source list (ui-panel 4). Nil: the
/// default of the row.
struct HeaderRowStyle: Equatable {
    let fill: NSColor?
    let text: NSColor?

    /// `emphasized`: the window is key.
    init(selected: Bool, emphasized: Bool) {
        fill =
            selected
            ? (emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor) : nil
        text = selected && emphasized ? .alternateSelectedControlTextColor : nil
    }
}
