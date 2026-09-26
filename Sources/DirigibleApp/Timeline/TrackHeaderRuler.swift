import AppKit
import SwiftUI

/// The track headers left of the lanes (decision 0017): SwiftUI rows in the vertical ruler of the
/// scroll view. The top of the clip view places them, so row n stays beside lane n in a vertical
/// scroll. A wheel over them goes up the responder chain to the scroll view.
final class TrackHeaderRuler: NSRulerView {
    static let width: CGFloat = 340
    let host = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(scrollView: nil, orientation: .verticalRuler)
        ruleThickness = Self.width
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        // macOS 14 does not clip subviews by default: a row above the lanes would cover the ruler.
        clipsToBounds = true
        host.sizingOptions = []
        addSubview(host)
    }

    required init(coder: NSCoder) { fatalError("no coder") }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {}

    /// `top` is the document y at the top of the clip view; `height` is the height of all lanes.
    func place(top: CGFloat, height: CGFloat) {
        let frame = NSRect(x: 0, y: -top, width: Self.width, height: height)
        if host.frame != frame { host.frame = frame }
    }
}
