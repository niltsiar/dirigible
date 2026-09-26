import AppKit
import DirigibleCore
import DirigibleTimeline

/// Every input that the ruler draws. The ruler redraws only when it changes.
struct RulerInputs: Equatable {
    var markers: [MarkerID: Marker]
    var marks: Marks
    var geometry: LaneGeometry
    var rate: Int
}

/// The time ruler over the lanes (decision 0017): time labels whose step follows the zoom, marker
/// flags (orange) and chapter flags (purple) with their names, and the in (green) and out (red)
/// triangles, drawn with the constants of `RulerGeometry` (decision 0020). A click seeks and does
/// not change the Marks.
final class TimelineRuler: NSRulerView {
    static let thickness = CGFloat(RulerGeometry.thickness)
    weak var model: SessionWindow?
    var inputs: RulerInputs? {
        didSet { if inputs != oldValue { needsDisplay = true } }
    }

    init(model: SessionWindow) {
        self.model = model
        super.init(scrollView: nil, orientation: .horizontalRuler)
        ruleThickness = Self.thickness
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
    }

    required init(coder: NSCoder) { fatalError("no coder") }

    /// The ruler x of a document x.
    private func x(of documentX: Double) -> Double {
        Double(convert(NSPoint(x: documentX, y: 0), from: scrollView?.documentView).x)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let inputs, let visible = (scrollView as? TimelineScrollView)?.shown else { return }
        let points = inputs.geometry.scale.framesPerPoint
        let rate = Double(max(1, inputs.rate))
        let labelFont: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        // A label every 80 pt or more.
        let steps: [Double] = [0.1, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let step = steps.first { $0 * rate / points >= 80 } ?? 7200
        let first = (Double(visible.minX) * points / rate / step).rounded(.down) * step
        var seconds = first
        NSColor.separatorColor.setFill()
        while seconds * rate / points <= Double(visible.maxX) {
            let at = x(of: seconds * rate / points)
            NSRect(x: at, y: Self.thickness - 6, width: 1, height: 6).fill()
            rulerLabel(seconds, tenths: step < 1).draw(at: NSPoint(x: at + 3, y: 2), withAttributes: labelFont)
            seconds += step
        }
        for marker in inputs.markers.values.sorted(by: { $0.position < $1.position }) {
            let color: NSColor = marker.kind == .marker ? .systemOrange : .systemPurple
            let at = x(of: inputs.geometry.x(of: marker.position))
            color.setFill()
            NSRect(x: at, y: 0, width: 1, height: Self.thickness).fill()
            let box = RulerGeometry.flagReach.upperBound
            NSRect(x: at, y: 12, width: box, height: box).fill()
            // A marker name is user data: it shows as typed.
            marker.name.draw(
                at: NSPoint(x: at + 8, y: 10),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: color])
        }
        triangle(inputs.marks.inPoint, inputs.geometry, .systemGreen)
        triangle(inputs.marks.outPoint, inputs.geometry, .systemRed)
    }

    private func triangle(_ frame: Frames?, _ geometry: LaneGeometry, _ color: NSColor) {
        guard let frame else { return }
        let at = x(of: geometry.x(of: frame))
        let (half, band) = (RulerGeometry.triangleHalfWidth, RulerGeometry.triangleBand)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: at - half, y: band.lowerBound))
        path.line(to: NSPoint(x: at + half, y: band.lowerBound))
        path.line(to: NSPoint(x: at, y: band.upperBound))
        path.close()
        color.setFill()
        path.fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let document = scrollView?.documentView, let inputs else { return }
        // The corner over the track headers is left of the lanes: no seek.
        let x = Double(document.convert(event.locationInWindow, from: nil).x)
        guard x >= 0 else { return }
        model?.rulerClick(at: inputs.geometry.frame(at: x))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}

/// A ruler label: m:ss, or h:mm:ss after an hour, with tenths when the step is under 1 s.
func rulerLabel(_ seconds: Double, tenths: Bool) -> String {
    let tenthsCount = Int((seconds * 10).rounded())
    let whole = tenthsCount / 10
    let (hours, minutes, rest) = (whole / 3600, whole / 60 % 60, whole % 60)
    var text =
        hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    if tenths { text += ".\(tenthsCount % 10)" }
    return text
}
