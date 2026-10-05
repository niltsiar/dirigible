import AppKit
import DirigibleCore

/// The dim of the lanes of the tracks that are not heard (decision 0039, ui-panel.md 6): one layer
/// per lane over the lane pixels, in the lane color of the palette at 50 % opacity. No lane pixel
/// is drawn again, so the lane benches do not change.
final class LaneDim {
    /// Above the lane surface, under the playhead and the readout.
    let layer = CALayer()

    private struct Shown: Equatable {
        /// The indices of the unheard lanes: a track move changes them.
        let lanes: [Int]
        let laneHeight: Double
        let width: Double
        let color: UInt32
    }

    private var shown: Shown?

    /// Sets the layers again only when the unheard lanes, the lane geometry, or the color changed.
    func update(_ session: Session, laneHeight: Double, width: Double, color: UInt32) {
        let lanes = session.tracks.indices.filter { !session.isAudible(session.tracks[$0].id) }
        let next = Shown(lanes: lanes, laneHeight: laneHeight, width: width, color: color)
        guard next != shown else { return }
        shown = next
        let fill = CGColor(
            srgbRed: Double(color >> 16 & 0xFF) / 255, green: Double(color >> 8 & 0xFF) / 255,
            blue: Double(color & 0xFF) / 255, alpha: 0.5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayers = lanes.map { lane in
            let dim = CALayer()
            dim.frame = CGRect(x: 0, y: Double(lane) * laneHeight, width: width, height: laneHeight)
            dim.backgroundColor = fill
            return dim
        }
        CATransaction.commit()
    }
}
