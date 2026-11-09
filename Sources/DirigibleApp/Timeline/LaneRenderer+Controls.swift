import DirigibleCore
import DirigibleTimeline
import Foundation

/// The gain line and the fade handles of a clip (run 11b-1), and the fade lines of a crossfade
/// (decision 0036).
extension LaneRenderer {
    /// The row of the fade line of a 0 dBFS signal at `gain` dB (the gains and the fade) in the
    /// lane whose last row is `bottom`: the top of the waveform of `drawColumns`.
    /// `clamp` rows under the lane top at the least: the line of an envelope clip.
    static func lineRow(_ gain: Double, bottom: Int, laneRows: Int, clamp: Int = 0) -> Int {
        let fraction = (gain + 60) / 60
        let height = fraction <= 0 ? 0 : Int((min(fraction, 1) * Double(laneRows)).rounded())
        return min(max(bottom - height + 1, bottom - laneRows + 1 + clamp), bottom)
    }

    /// The rows that the line of an envelope clip stays under the top of its lane (`lineClamp`).
    static func lineClamp(scale: Double) -> Int { Int((LaneGeometry.lineClamp * scale).rounded()) }

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
        guard geometry.box(of: clip, lane: lane).width >= 12, let index = track.clips.index(holding: clip.start) else {
            return
        }
        let window = region.window
        let (scale, edges) = (window.scale, track.clips.sounding(at: index))
        let (curves, sounding) = (edges.curves, edges.clip)
        let pixelFrames = geometry.scale.framesPerPoint / scale
        let (bottom, gain) = (window.rows(of: lane..<lane + 1).upperBound - 1, clip.gain.dB + track.gain.dB)
        let clamp = sounding.hasLayers ? Self.lineClamp(scale: scale) : 0
        func column(_ frame: Frames) -> Int { Int((geometry.x(of: frame) * scale).rounded(.up)) }
        for part in [column(sounding.start)..<column(clip.start), column(clip.end)..<column(sounding.end)] {
            let columns = part.clamped(to: region.rect.columns)
            guard !columns.isEmpty else { continue }
            let fades = ColumnFades(
                fades: sounding.fades, curves: curves, length: sounding.length,
                first: Double(columns.lowerBound) * pixelFrames - Double(sounding.start.count), step: pixelFrames,
                line: true)
            var envelope =
                sounding.hasLayers
                ? ColumnEnvelope(
                    layers: [sounding.envelope, sounding.ride],
                    first: Double(sounding.offset.count) + Double(columns.lowerBound) * pixelFrames
                        - Double(sounding.start.count),
                    step: pixelFrames) : nil
            for column in columns {
                guard let factor = fades.factor(column - columns.lowerBound) else { continue }
                let columnGain = gain + 20 * log10(factor) + (envelope?.gain(column - columns.lowerBound) ?? 0)
                let row = Self.lineRow(columnGain, bottom: bottom, laneRows: window.laneRows, clamp: clamp)
                region.span(palette.label, column: column, rows: row..<row + 1)
            }
        }
    }

    /// The gain line of `clip` in the columns that no fade line takes, at the top of a 0 dBFS
    /// signal with the gains (over 0 dB on the top row, dashed 3 px on and 3 px off in absolute
    /// columns), and its fade handles: each handle rect inset by 1 pt, filled in the label color.
    /// With gain layers (decision 0060), the line has the row of each column, with the highest
    /// gain of the layers over its frames, at least `lineClamp` under the lane top and joined to the
    /// row of the column before it, and each shown point of the envelope is a disc. `layerGains`:
    /// the layer gain of each column of the box in the rect (`columnGains`), nil with no gain layer.
    func drawControls(
        _ clip: Clip, _ track: Track, _ lane: Int, _ geometry: LaneGeometry, _ palette: LanePalette,
        layerGains: ArraySlice<Double>?, into region: borrowing PixelRegion
    ) {
        let scale = region.window.scale
        let (rows, pixelFrames) = (region.window.rows(of: lane..<lane + 1), geometry.scale.framesPerPoint / scale)
        let gain = clip.gain.dB + track.gain.dB
        let height = Int((LaneGeometry.gainFraction(dB: gain) * Double(rows.count)).rounded())
        let row = min(rows.upperBound - height, rows.upperBound - 1)
        func column(_ frame: Frames) -> Int { Int((geometry.x(of: frame) * scale).rounded(.up)) }
        let box = column(clip.start)..<column(clip.end)
        let columns = box.clamped(to: region.rect.columns)
        guard !columns.isEmpty, let index = track.clips.index(holding: clip.start) else { return }
        // The columns of `drawColumns` with no fade factor: one run between the fade-in and the
        // fade-out columns, which have the fade line. A crossfade is the fade of its edge (0036).
        let edges = track.clips.sounding(at: index)
        let (curves, sounding) = (edges.curves, edges.clip)
        let fades = ColumnFades(
            fades: sounding.fades, curves: curves, length: sounding.length,
            first: Double(columns.lowerBound) * pixelFrames - Double(sounding.start.count), step: pixelFrames,
            line: true)
        var (low, high) = (columns.lowerBound, columns.upperBound)
        while low < high, fades.factor(low - columns.lowerBound) != nil { low += 1 }
        while high > low, fades.factor(high - 1 - columns.lowerBound) != nil { high -= 1 }
        if let layerGains {
            let clamp = Self.lineClamp(scale: scale)
            var previous: Int?
            for column in low..<high {
                let columnGain = gain + layerGains[layerGains.startIndex + column - columns.lowerBound]
                let row = Self.lineRow(
                    columnGain, bottom: rows.upperBound - 1, laneRows: rows.count, clamp: clamp)
                // Over 0 dB the line is dashed, with no joint.
                if columnGain <= 0 || (column / 3) % 2 == 0 {
                    let (top, bottom) = (min(row, previous ?? row), max(row, previous ?? row))
                    region.span(palette.label, column: column, rows: top..<bottom + 1)
                }
                previous = columnGain <= 0 ? row : nil
            }
            let radius = LaneGeometry.pointRadius * scale
            for point in geometry.envelopePoints(
                of: clip, at: index, in: track.clips, trackGain: track.gain, lane: lane)
            {
                fillDisc(
                    palette.label, x: point.x * scale, y: point.y * scale, radius: radius, within: box, into: region)
            }
        } else if gain <= 0 {
            region.fill(palette.label, columns: low..<high, rows: row..<row + 1)
        } else {
            for column in low..<high where (column / 3) % 2 == 0 {
                region.span(palette.label, column: column, rows: row..<row + 1)
            }
        }
        let handles = geometry.fadeHandles(of: clip, at: index, in: track.clips, lane: lane)
        func pixel(_ value: Double) -> Int { Int((value * scale).rounded()) }
        for handle in [handles.start, handles.end].compactMap({ $0 }) {
            region.fill(
                palette.label, columns: pixel(handle.minX + 1)..<pixel(handle.maxX - 1),
                rows: pixel(handle.minY + 1)..<pixel(handle.maxY - 1))
        }
    }

    /// A disc: each pixel whose center is within `radius` of the center, in the columns `box` only.
    /// All values are in pixels.
    private func fillDisc(
        _ color: UInt32, x: Double, y: Double, radius: Double, within box: Range<Int>,
        into region: borrowing PixelRegion
    ) {
        for row in Int((y - radius).rounded(.down))...Int((y + radius).rounded(.up)) {
            let dy = Double(row) + 0.5 - y
            guard abs(dy) <= radius else { continue }
            let half = (radius * radius - dy * dy).squareRoot()
            let columns = Int((x - half - 0.5).rounded(.up))..<Int((x + half - 0.5).rounded(.down)) + 1
            region.fill(color, columns: columns.clamped(to: box), rows: row..<row + 1)
        }
    }
}
