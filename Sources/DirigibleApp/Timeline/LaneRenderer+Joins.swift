import DirigibleCore
import DirigibleTimeline
import Foundation

extension LaneRenderer {
    /// The join at each cut between two clips of a lane: 2 pt of `palette.join` over the full lane
    /// height, centered on the cut, when both boxes are `LaneGeometry.grabWidth` or wider (a
    /// narrower box has no grab or label either). `inView` are the clips of `clips` that the draw
    /// reaches. Each clip draws the join before it, and the last also the join after it, so a draw
    /// whose columns end in the left half of a join, or start in its right half, draws it as a full
    /// draw does. The pass runs after the waveforms and the gain lines, so they do not cover it.
    func drawJoins(
        _ inView: [Clip], of clips: ClipLane, lane: Int, _ geometry: LaneGeometry, _ palette: LanePalette,
        into region: borrowing PixelRegion
    ) {
        guard let first = inView.first, let base = clips.index(holding: first.start) else { return }
        let (window, last) = (region.window, inView.count - 1)
        let rows = window.rows(of: lane..<lane + 1)
        func wide(_ clip: Clip) -> Bool { geometry.box(of: clip, lane: lane).width >= LaneGeometry.grabWidth }
        func draw(at frame: Frames) {
            let center = Int((geometry.x(of: frame) * window.scale).rounded())
            let half = Int(window.scale.rounded())
            region.fill(palette.join, columns: center - half..<center + half, rows: rows)
        }
        for (offset, clip) in inView.enumerated() {
            let joins = clips.joins(at: base + offset)
            if joins.before, wide(clip), wide(clips[base + offset - 1]) { draw(at: clip.start) }
            if joins.after, offset == last, wide(clip), wide(clips[base + offset + 1]) { draw(at: clip.end) }
        }
    }
}
