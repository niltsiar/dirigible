import AppKit
import DirigibleCore

/// One layer per lane over the lane pixels, in one color: the dim of the tracks that are not heard
/// (decision 0039, ui-panel.md 6) and the tint of the selected tracks (run
/// 2026-10-11-ui-polish-header C11). No lane pixel is drawn again, so the lane benches do not
/// change.
final class LaneShade {
    /// Above the lane surface, under the playhead and the readout.
    let layer = CALayer()

    private struct Shown: Equatable {
        /// The indices of the shaded lanes: a track move changes them.
        let lanes: [Int]
        let laneHeight: Double
        let width: Double
        let color: UInt32
        let alpha: Double
    }

    private var shown: Shown?

    /// Sets the layers again only when the lanes, the lane geometry, or the color changed.
    func update(lanes: [Int], laneHeight: Double, width: Double, color: UInt32, alpha: Double) {
        let next = Shown(lanes: lanes, laneHeight: laneHeight, width: width, color: color, alpha: alpha)
        guard next != shown else { return }
        shown = next
        let fill = cgColor(color, alpha: alpha)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayers = lanes.map { lane in
            let shade = CALayer()
            shade.frame = CGRect(x: 0, y: Double(lane) * laneHeight, width: width, height: laneHeight)
            shade.backgroundColor = fill
            return shade
        }
        CATransaction.commit()
    }

    /// The lanes of the tracks that are not heard. An armed track of a take keeps its lane bright,
    /// so its live take does not look dead.
    static func unheard(_ session: Session) -> [Int] {
        let bright = Set(session.heardTracks(in: nil).map(\.id)).union(session.recording?.armedTracks ?? [])
        return session.tracks.indices.filter { !bright.contains(session.tracks[$0].id) }
    }

    /// The lanes of the tracks that the headers show as selected: the tracks of a range, not of a
    /// clip set (decision 0038).
    static func selected(_ inputs: LaneInputs) -> [Int] {
        let tracks = Set(inputs.selection.headerTracks(in: inputs.session))
        return inputs.session.tracks.indices.filter { tracks.contains(inputs.session.tracks[$0].id) }
    }
}
