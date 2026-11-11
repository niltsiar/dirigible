import AppKit
import SwiftUI

/// A zero-size view in a row of the Silences list. It finds the `NSTableView` that holds the row
/// and gives it to `SilenceState.table`.
struct SilenceTableMarker: NSViewRepresentable {
    let state: SilenceState

    func makeNSView(context: Context) -> SilenceTableMarkerView {
        let view = SilenceTableMarkerView()
        view.state = state
        return view
    }

    func updateNSView(_ view: SilenceTableMarkerView, context: Context) { view.state = state }
}

final class SilenceTableMarkerView: NSView {
    weak var state: SilenceState?
    private weak var found: NSTableView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            // A rebuilt list adds its marker before the old one leaves: clear only our own table.
            if let state, state.table === found { state.table = nil }
            return
        }
        var view = superview
        while let current = view, !(current is NSTableView) { view = current.superview }
        found = view as? NSTableView
        if let found { state?.table = found }
    }
}
