import AppKit

/// The colors of the playhead (run timeline-clarity, U-c2): a neutral core with a halo of the
/// opposite tone, so the line shows over a selected and an unselected lane. The core is red only as
/// the record head of a take.
struct PlayheadColors: Equatable {
    var core: CGColor
    var halo: CGColor

    init(appearance: NSAppearance, taking: Bool) {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        halo = CGColor(gray: dark ? 0 : 1, alpha: dark ? 0.7 : 0.85)
        var core = CGColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1)
        if dark { core = CGColor(gray: 1, alpha: 1) }
        if taking { appearance.performAsCurrentDrawingAppearance { core = NSColor.systemRed.cgColor } }
        self.core = core
    }
}

/// The actions of a layer that follows the playhead at once: no implicit animation of `keys`.
private func still(_ keys: String...) -> [String: any CAAction] {
    keys.reduce(into: [:]) { $0[$1] = NSNull() }
}

/// The playhead line over the lanes: a core layer of 1 pt (2 pt with Increase Contrast) with a halo
/// layer of 1 pt on each side. The document view moves the core by `position`.
final class PlayheadLine: CALayer {
    private let halos = [CALayer(), CALayer()]

    override init() {
        super.init()
        actions = still("position", "bounds", "backgroundColor")
        for halo in halos {
            halo.actions = still("position", "bounds", "backgroundColor")
            addSublayer(halo)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The core is `width` wide and `height` high; the halos stand on its two sides.
    func resize(width: Double, height: Double) {
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        halos[0].frame = CGRect(x: -1, y: 0, width: 1, height: height)
        halos[1].frame = CGRect(x: width, y: 0, width: 1, height: height)
    }

    func apply(_ colors: PlayheadColors) {
        backgroundColor = colors.core
        for halo in halos { halo.backgroundColor = colors.halo }
    }
}

/// The head of the playhead on the time ruler (U-c3): a pentagon in the top 10 pt, 11 x 10 pt
/// (13 x 12 pt with Increase Contrast), in the color of the line with the halo as outline. It sits in
/// a container that starts at the left edge of the lanes in view and clips, so no part of it shows
/// over the track headers. It moves by `position`, with no ruler draw, and only when its pixel
/// column or its container changes.
final class PlayheadHead {
    let container = CALayer()
    let shape = CAShapeLayer()
    private var wide = false
    private var taking = false
    private var appearance = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
    private var placed: (column: Int, edge: Int, width: Int, wide: Bool)?

    init() {
        container.masksToBounds = true
        // AppKit adds its own layers to the ruler after init: stay over them.
        container.zPosition = 100
        container.actions = still("position", "bounds")
        shape.actions = still("position", "bounds", "path", "fillColor", "strokeColor")
        container.anchorPoint = .zero
        shape.anchorPoint = CGPoint(x: 0.5, y: 0)
        shape.lineWidth = 1
        container.addSublayer(shape)
        restyle()
    }

    /// The look follows the effective appearance of the document view, which calls this from
    /// `showPlayheadColors`.
    func show(appearance: NSAppearance, wide: Bool) {
        guard appearance != self.appearance || wide != self.wide else { return }
        (self.appearance, self.wide) = (appearance, wide)
        restyle()
    }

    /// Puts the tip of the head at the ruler x `x`, in a container from the ruler x `edge` to the
    /// ruler width `width`. The ruler is a flipped view: y 0 of its layer is the top of the ruler.
    func place(at x: Double, edge: Double, width: Double, taking: Bool, scale: Double) {
        if taking != self.taking {
            self.taking = taking
            restyle()
        }
        let key = (
            Int((x * scale).rounded(.down)), Int((edge * scale).rounded(.down)), Int((width * scale).rounded(.down)),
            wide
        )
        if let placed, placed == key { return }
        placed = key
        container.frame = CGRect(x: edge, y: 0, width: max(0, width - edge), height: size.height)
        shape.position = CGPoint(x: x - edge, y: 0)
    }

    private var size: CGSize { wide ? CGSize(width: 13, height: 12) : CGSize(width: 11, height: 10) }

    private func restyle() {
        let colors = PlayheadColors(appearance: appearance, taking: taking)
        let (w, h) = (size.width, size.height)
        let path = CGMutablePath()
        path.addLines(between: [
            CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h * 0.6), CGPoint(x: w / 2, y: h),
            CGPoint(x: 0, y: h * 0.6),
        ])
        path.closeSubpath()
        container.frame.size.height = h
        shape.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        shape.path = path
        shape.fillColor = colors.core
        shape.strokeColor = colors.halo
        placed = nil
    }
}
