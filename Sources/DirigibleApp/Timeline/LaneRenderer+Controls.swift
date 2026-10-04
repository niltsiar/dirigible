import DirigibleCore
import DirigibleTimeline
import Foundation

/// The gain line and the fade handles of a clip (run 11b-1), and the fade lines of a crossfade
/// (decision 0036).
extension LaneRenderer {
    /// The row of the fade line of a 0 dBFS signal at `gain` dB (the gains and the fade) in the
    /// lane whose last row is `bottom`: the top of the waveform of `drawColumns`.
    static func lineRow(_ gain: Double, bottom: Int, laneRows: Int) -> Int {
        let fraction = (gain + 60) / 60
        let height = fraction <= 0 ? 0 : Int((min(fraction, 1) * Double(laneRows)).rounded())
        return min(bottom - height + 1, bottom)
    }

    /// Adds to `crossfaded` each clip of `inView` with a crossfade, and the lane neighbor just
    /// before the first and just after the last of them when its crossfade half reaches into the
    /// box of that clip: a half reaches only into the box of its neighbor (decision 0036).
    func collectCrossfades(_ inView: [Clip], of clips: ClipLane, lane: Int) {
        for clip in inView where clip.crossfades != .zero { crossfaded.append((lane, clip)) }
        if let first = inView.first, first.crossfades.start != .zero, let index = clips.index(holding: first.start),
            index > clips.startIndex
        {
            crossfaded.append((lane, clips[index - 1]))
        }
        if let last = inView.last, last.crossfades.end != .zero, let index = clips.index(holding: last.start),
            index + 1 < clips.endIndex
        {
            crossfaded.append((lane, clips[index + 1]))
        }
    }

    /// The fade line of each crossfade half of `clip` outside its box: over the box of the
    /// neighbor, from the join to the end of the half. `drawColumns` draws the line inside the
    /// box. Only in boxes of 12 pt or more, as the fade line; never a waveform outside the box.
    func drawCrossfadeLines(
        _ clip: Clip, _ track: Track, _ lane: Int, _ geometry: LaneGeometry, _ palette: LanePalette,
        into region: borrowing PixelRegion
    ) {
        guard geometry.box(of: clip, lane: lane).width >= 12 else { return }
        let window = region.window
        let (scale, sounding) = (window.scale, clip.sounding)
        let pixelFrames = geometry.scale.framesPerPoint / scale
        let (bottom, gain) = (window.rows(of: lane..<lane + 1).upperBound - 1, clip.gain.dB + track.gain.dB)
        func column(_ frame: Frames) -> Int { Int((geometry.x(of: frame) * scale).rounded(.up)) }
        for part in [column(sounding.start)..<column(clip.start), column(clip.end)..<column(sounding.end)] {
            let columns = part.clamped(to: region.rect.columns)
            guard !columns.isEmpty else { continue }
            let fades = ColumnFades(
                fades: sounding.fades, length: sounding.length,
                first: Double(columns.lowerBound) * pixelFrames - Double(sounding.start.count), step: pixelFrames,
                line: true)
            for column in columns {
                guard let factor = fades.factor(column - columns.lowerBound) else { continue }
                let row = Self.lineRow(gain + 20 * log10(factor), bottom: bottom, laneRows: window.laneRows)
                region.span(palette.label, column: column, rows: row..<row + 1)
            }
        }
    }

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
        // fade-out columns, which have the fade line. A crossfade is the fade of its edge (0036).
        let sounding = clip.sounding
        let fades = ColumnFades(
            fades: sounding.fades, length: sounding.length,
            first: Double(columns.lowerBound) * pixelFrames - Double(sounding.start.count), step: pixelFrames,
            line: true)
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
