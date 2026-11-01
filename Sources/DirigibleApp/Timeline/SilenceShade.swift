import AppKit
import DirigibleCore
import DirigibleTimeline

/// One layer over the lanes for the silence list (decision 0066): each silence shaded over all
/// lanes, and the cut that a Shorten row removes darker. With Increase Contrast on, the cut also has
/// an edge and a hatch. Like `LaneShade`, it draws no lane pixel again, so the lane benches do not
/// change.
final class SilenceShade {
    let layer = CALayer()
    private let silences = CAShapeLayer()
    private let cuts = CAShapeLayer()
    private let hatch = CAShapeLayer()

    private struct Shown: Equatable {
        let bands: [SilenceBand]
        let geometry: LaneGeometry
        let height: Double
        let width: Double
        let contrast: Bool
        let color: UInt32
    }

    private var shown: Shown?

    init() {
        layer.addSublayer(silences)
        layer.addSublayer(cuts)
        layer.addSublayer(hatch)
        hatch.fillColor = nil
        hatch.lineDashPattern = [2, 4]
        cuts.fillColor = nil
    }

    /// The bands that the layer shows, in document points. Nothing changes when the inputs match.
    func update(
        bands: [SilenceBand], geometry: LaneGeometry?, height: Double, width: Double, contrast: Bool, color: UInt32
    ) {
        guard let geometry, !bands.isEmpty else {
            if shown != nil { clear() }
            return
        }
        let next = Shown(
            bands: bands, geometry: geometry, height: height, width: width, contrast: contrast, color: color)
        guard next != shown else { return }
        shown = next
        let (silencePath, cutPath, hatchPath) = (CGMutablePath(), CGMutablePath(), CGMutablePath())
        for band in bands {
            silencePath.addRect(rect(band.silence, geometry, height))
            guard let cut = band.cut else { continue }
            cutPath.addRect(rect(cut, geometry, height))
            let (x0, x1) = (geometry.x(of: cut.lowerBound), geometry.x(of: cut.upperBound))
            hatchPath.move(to: CGPoint(x: x0, y: height / 2))
            hatchPath.addLine(to: CGPoint(x: x1, y: height / 2))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        for part in [silences, cuts, hatch] { part.frame = layer.bounds }
        silences.path = silencePath
        silences.fillColor = cgColor(color, alpha: 0.12)
        cuts.path = cutPath
        cuts.fillColor = cgColor(color, alpha: contrast ? 0.30 : 0.22)
        cuts.strokeColor = contrast ? cgColor(color) : nil
        cuts.lineWidth = contrast ? 2 : 0
        hatch.path = contrast ? hatchPath : nil
        hatch.strokeColor = cgColor(color, alpha: 0.8)
        hatch.lineWidth = height
        CATransaction.commit()
    }

    private func rect(_ range: Range<Frames>, _ geometry: LaneGeometry, _ height: Double) -> CGRect {
        let (x0, x1) = (geometry.x(of: range.lowerBound), geometry.x(of: range.upperBound))
        return CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: height)
    }

    private func clear() {
        shown = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in [silences, cuts, hatch] { part.path = nil }
        CATransaction.commit()
    }
}
