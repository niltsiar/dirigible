import AppKit

/// The look of a header row. A selected row in a key window shows a light tint of the accent color;
/// in another window it shows the source list fill that macOS gives an unfocused selection. Nil:
/// the default of the row. The labels keep their normal text color in each state.
struct HeaderRowStyle: Equatable {
    let fill: NSColor?

    /// `emphasized`: the window is key.
    init(selected: Bool, emphasized: Bool) {
        fill =
            selected
            ? (emphasized
                ? NSColor.controlAccentColor.withAlphaComponent(0.22) : .unemphasizedSelectedContentBackgroundColor)
            : nil
    }
}
