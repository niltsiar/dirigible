import DirigibleCore
import DirigibleTimeline

/// The gain line and the fade handles of a clip (run 11b-1).
extension LaneRenderer {
    /// The gain line of `clip` in the columns that no fade line takes, at the top of a 0 dBFS
    /// signal with the gains (over 0 dB on the top row, dashed 3 px on and 3 px off in absolute
    /// columns), and its fade handles: each handle rect inset by 1 pt, filled in the label color.
    func drawControls(
        _ clip: Clip, _ track: Track, _ lane: Int, _ geometry: LaneGeometry, _ palette: LanePalette,
        into region: borrowing PixelRegion
    ) {
        let scale = region.window.scale
        let (rows, pixelFrames) = (region.window.rows(of: lane..<lane + 1), geometry.scale.framesPerPoint / scale)
        let gain = clip.gain.dB + track.gain.dB
        let height = Int((LaneGeometry.gainFraction(dB: gain) * Double(rows.count)).rounded())
        let row = min(rows.upperBound - height, rows.upperBound - 1)
        func column(_ frame: Frames) -> Int { Int((geometry.x(of: frame) * scale).rounded(.up)) }
        let columns = (column(clip.start)..<column(clip.end)).clamped(to: region.rect.columns)
        guard !columns.isEmpty else { return }
        // The columns of `drawColumns` with no fade factor: one run between the fade-in and the
        // fade-out columns, which have the fade line.
        let fades = ColumnFades(
            fades: clip.fades, length: clip.length,
            first: Double(columns.lowerBound) * pixelFrames - Double(clip.start.count), step: pixelFrames, line: true)
        var (low, high) = (columns.lowerBound, columns.upperBound)
        while low < high, fades.factor(low - columns.lowerBound) != nil { low += 1 }
        while high > low, fades.factor(high - 1 - columns.lowerBound) != nil { high -= 1 }
        if gain <= 0 {
            region.fill(palette.label, columns: low..<high, rows: row..<row + 1)
        } else {
            for column in low..<high where (column / 3) % 2 == 0 {
                region.span(palette.label, column: column, rows: row..<row + 1)
            }
        }
        guard let index = track.clips.index(holding: clip.start) else { return }
        let handles = geometry.fadeHandles(of: clip, at: index, in: track.clips, lane: lane)
        func pixel(_ value: Double) -> Int { Int((value * scale).rounded()) }
        for handle in [handles.start, handles.end].compactMap({ $0 }) {
            region.fill(
                palette.label, columns: pixel(handle.minX + 1)..<pixel(handle.maxX - 1),
                rows: pixel(handle.minY + 1)..<pixel(handle.maxY - 1))
        }
    }
}
