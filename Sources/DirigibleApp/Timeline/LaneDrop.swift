import AppKit

/// A drag of audio files from the Finder over the lanes (run 13c): the files of the drag, and the
/// cue of the drop target (`ui-panel.md` items 1 to 9). The cue is layers over the lane pixels
/// (decision 0022), made once: a lane tint with an accent border for one file over a lane, a
/// drop line at the pointer, and a New Track row for new tracks. An update writes frames and
/// `isHidden` only, so it draws no lane pixel and nothing animates.
final class LaneDrop {
    /// The audio files of the drag: the files of `AppDelegate.importTypes`, in the drag order.
    /// The drag holds them from the drag enter to the end of the drag session.
    var urls: [URL] = []
    /// Over the dim (0039), under the playhead.
    let layer = CALayer()
    let tint = CALayer()
    let line = CALayer()
    let row = CAShapeLayer()
    let text = CATextLayer()
    /// The palette of the lanes: the accent and the label color of the cue.
    var palette = LanePalette.light {
        didSet { setColors() }
    }

    init() {
        layer.zPosition = 5
        for sublayer in [tint, line, row, text] as [CALayer] {
            sublayer.isHidden = true
            layer.addSublayer(sublayer)
        }
        row.lineDashPattern = [4, 3]
        text.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        text.fontSize = 12
        text.truncationMode = .end
        setColors()
    }

    /// Shows the cue of a drop on the lane `lane`, or on new tracks for nil, at the document x `x`.
    /// The row is one lane high at `newTrackTop`; the view clips it. The tint, the row, and the
    /// text take the lanes in view `shown`, never the document width. `contrast`: 2 pt lines.
    func show(
        lane: Int?, x: Double, files: Int, lanes: Int, laneHeight: Double, newTrackTop: Double, shown: NSRect,
        contrast: Bool, scale: Double
    ) {
        let width = contrast ? 2.0 : 1.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        (tint.isHidden, row.isHidden, text.isHidden, line.isHidden) = (lane == nil, lane != nil, lane != nil, false)
        if let lane {
            tint.frame = CGRect(x: shown.minX, y: Double(lane) * laneHeight, width: shown.width, height: laneHeight)
            tint.borderWidth = width
            line.frame = CGRect(x: x, y: 0, width: width, height: Double(lanes) * laneHeight)
        } else {
            let frame = CGRect(x: shown.minX, y: newTrackTop, width: shown.width, height: laneHeight)
            row.frame = frame
            row.lineWidth = width
            let inset = CGRect(origin: .zero, size: frame.size).insetBy(dx: width / 2, dy: width / 2)
            row.path = CGPath(roundedRect: inset, cornerWidth: 4, cornerHeight: 4, transform: nil)
            let label = Self.label(files: files)
            // A new string renders the text again, so only a new count sets it.
            if text.string as? String != label { text.string = label }
            text.contentsScale = scale
            // Centered in the part of the row in view.
            let visible = min(frame.maxY, shown.maxY) - frame.minY
            text.frame = CGRect(
                x: shown.minX + 12, y: frame.minY + (visible - 16) / 2, width: max(0, shown.width - 24), height: 16)
            line.frame = CGRect(x: x, y: 0, width: width, height: frame.maxY)
        }
        CATransaction.commit()
    }

    /// The label of the cue of new tracks: "New Track" for one file, else the count.
    static func label(files: Int) -> String {
        files == 1 ? L10n.dropNewTrack.text : L10n.dropNewTracks.format(files)
    }

    func hide() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [tint, line, row, text] as [CALayer] { sublayer.isHidden = true }
        CATransaction.commit()
    }

    private func setColors() {
        let (accent, fill) = (cgColor(palette.outline), palette.dropFill)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        (tint.backgroundColor, tint.borderColor, line.backgroundColor) = (fill, accent, accent)
        (row.fillColor, row.strokeColor, text.foregroundColor) = (fill, accent, cgColor(palette.label))
        CATransaction.commit()
    }
}

extension LanePalette {
    /// The accent fill of a drop cue is 8 % in light mode and 12 % in Dark Mode. Only the dark
    /// palette blends the selection band toward the accent, so `accent` tells the two apart.
    var dropFill: CGColor { cgColor(outline, alpha: accent == nil ? 0.08 : 0.12) }
}

/// The color of a palette pixel (0xAARRGGBB) with `alpha`.
func cgColor(_ pixel: UInt32, alpha: Double = 1) -> CGColor {
    CGColor(
        srgbRed: Double(pixel >> 16 & 0xFF) / 255, green: Double(pixel >> 8 & 0xFF) / 255,
        blue: Double(pixel & 0xFF) / 255, alpha: alpha)
}
