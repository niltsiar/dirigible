import Accelerate
import AppKit
import CoreGraphics
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation

/// Every input that the lane pixels read (decision 0017), except the backing scale and the live
/// take. The document view redraws when this value changes. The live take (`LiveLanes`) is a drawn
/// input outside it, with its own invalidation (`TimelineScrollView.liveTick`): an append marks
/// its columns, and any other store change redraws the lanes in view. So a display tick does not
/// make SwiftUI compare the bins. Every full draw reads the live take.
struct LaneInputs: Equatable {
    var session: Session
    var peaks: [FileID: PeakState]
    var missingMedia: [FileID: MediaFault]
    var selection: Selection
    var scale: TimelineScale
    /// Points.
    var laneHeight: Double
    /// The dB that the lane height shows: the waveform, the fade lines, and the gain lines draw with it.
    var range: WaveformRange

    /// The one point and frame conversion of the lanes (decision 0020).
    var geometry: LaneGeometry? { LaneGeometry(scale: scale, laneHeight: laneHeight, range: range) }
    /// The range that draws its band and lines; no Marks for a clip set (decision 0038).
    var marks: Marks { selection.marks ?? Marks() }
}

/// Draws the lanes into a caller's pixels (decisions 0017 and 0022, probe D2): a background pattern
/// per row, then the clip boxes with their bars, the missing-media tint, and the waveform as column
/// spans, rectified on the dB scale of the waveform range (0 dB at the lane top, 60 dB per lane height
/// by default), light peaks over dark RMS, with clip gain plus track gain and the fades of decision
/// 0035, and a fade line in clip boxes of 12 pt or more. Then the fade lines of the crossfade halves
/// outside the boxes (decision 0036), the bar edges, the gain lines and handles, the joins between
/// clips that touch, the selection band and the marker, chapter, in, and out lines. One per document
/// view, on the main thread. It writes every pixel of the rect of the region, and the region refuses
/// every pixel outside it. Each edge rounds in absolute document pixels, so two partial draws agree with
/// one full draw on each pixel. It keeps no pixel state. A drag event redraws only the columns that
/// `changedFrames` gives, so each Session value drawn here needs a compare there (decision 0020, the
/// invariant).
final class LaneRenderer {
    /// The columns of one clip, reused.
    var values: [PeakColumn] = []
    /// The clips with a crossfade that the fade-line pass draws, with their lanes, reused. The
    /// waveform pass collects them, so a draw with no crossfade scans no lane again.
    var crossfaded: [(lane: Int, clip: Clip)] = []
    /// The pixel columns of each clip bar of the draw and the first row of its lane, reused. The box
    /// pass fills the bars and collects them, and the edge pass draws their bottom rows.
    var bars: [(columns: Range<Int>, top: Int)] = []
    /// The layer gains of each column of the clips with gain layers in the draw, which the waveform
    /// pass gets and the gain line reads again.
    var layerGains: [ClipID: ArraySlice<Double>] = [:]
    /// The layer gains of clips of earlier draws (`columnGains`), so a draw of the same layers, clip
    /// window, and zoom walks no layer. Only the clips that the last display event read or walked
    /// stay, each with its columns in the rect and at most one window width more on each side:
    /// about 3 window widths of `Double` per lane of that window.
    var layerColumns: [ClipID: LayerColumns] = [:]
    /// The layer walks of `columnGains`, for the tests.
    var walks = 0
    /// The display event of the draws, the count of `layerColumns` entries that it read or walked,
    /// and whether a `display` is open.
    private(set) var event = 0
    var eventEntries = 0
    private var displaying = false

    /// Runs `body`, whose draws are the parts of one display event: they keep the layer gains of
    /// each other. A draw outside `display` is a display event of its own.
    func display<Result>(_ body: () -> Result) -> Result {
        displaying = true
        defer {
            displaying = false
            endEvent()
        }
        return body()
    }

    /// Keeps only the layer gains of the clips of this event, if it read or walked any.
    private func endEvent() {
        guard eventEntries > 0 else { return }
        if layerColumns.count > eventEntries { layerColumns = layerColumns.filter { $0.value.event == event } }
        (event, eventEntries) = (event + 1, 0)
    }

    /// 20 log10(v / 65535) for each magnitude v.
    private static let decibels: [Double] = (0...65535).map { 20 * log10(Double($0) / 65535) }

    /// Draws the rect of `region`: the lanes that its rows cross, in its columns. Then the live
    /// take over the clips. Each label of `labels` gets its chip: no peak or RMS span there.
    func draw(
        _ inputs: LaneInputs, _ palette: LanePalette, live: LiveLanes = LiveLanes(), labels: [ClipLabel] = [],
        into region: borrowing PixelRegion
    ) {
        let (window, rect) = (region.window, region.rect)
        guard !rect.isEmpty, let geometry = inputs.geometry else { return }
        let scale = window.scale
        let tracks = inputs.session.tracks
        let drawn = window.lanes(of: rect.rows).clamped(to: tracks.indices)
        let pixelFrames = inputs.scale.framesPerPoint / scale
        /// The absolute column of a timeline frame, not clamped: the x of `LaneGeometry`, so a clip
        /// draws where the hit test finds it.
        func column(_ frame: Frames) -> Double { geometry.x(of: frame) * scale }
        let (first, end) = (rect.columns.lowerBound, rect.columns.upperBound)
        func clamped(_ value: Double) -> Int { Int(min(max(value, Double(first)), Double(end))) }
        let visible = Frames(Int(Double(first) * pixelFrames))..<Frames(Int(Double(end) * pixelFrames) + 1)

        // First the boxes of every lane, then the waveforms, so a span that passes its lane shows.
        bars.removeAll(keepingCapacity: true)
        let barRows = Int((ClipLabel.barHeight * scale).rounded())
        for lane in drawn {
            let track = tracks[lane]
            let rows = window.rows(of: lane..<lane + 1)
            // Each pixel gets one background: the lane color only in the gaps between the clips.
            var gap = first
            // The columns of adjacent clips that are not filled yet: one fill for a run of clips,
            // not one per clip (2,000 clips of 1 or 2 columns took 14 ms at fit zoom).
            var run: Range<Int>?
            let firstBar = bars.count
            func fillRun() {
                if let run { region.fill(palette.clip, columns: run, rows: rows) }
                run = nil
            }
            for clip in track.clips.clips(overlapping: visible) {
                let range = clamped(column(clip.start).rounded(.down))..<clamped(column(clip.end).rounded(.up))
                guard !range.isEmpty else { continue }
                if gap < range.lowerBound {
                    fillRun()
                    region.fill(palette.lane, columns: gap..<range.lowerBound, rows: rows)
                }
                gap = max(gap, range.upperBound)
                run = (run?.lowerBound ?? range.lowerBound)..<max(run?.upperBound ?? 0, range.upperBound)
                // The red comes from the media check only, never from the peaks.
                var red: Int?
                switch inputs.missingMedia[clip.file] {
                case .missing, .unreadable: red = range.lowerBound
                case .short(let real): red = clamped(column(clip.start + real - clip.offset).rounded(.up))
                case nil: break
                }
                // The bar runs to the red column: the missing tint covers the rest.
                if ClipLabel.hasBar(width: geometry.box(of: clip, lane: lane).width, laneHeight: inputs.laneHeight) {
                    let barEnd = red.map { min(max($0, range.lowerBound), range.upperBound) } ?? range.upperBound
                    if barEnd > range.lowerBound { bars.append((range.lowerBound..<barEnd, rows.lowerBound)) }
                }
                if let red, red < range.upperBound {
                    // The tint goes over the clip color, so the run fills first.
                    fillRun()
                    let tint = max(red, range.lowerBound)..<range.upperBound
                    region.fill(palette.missing, columns: tint, rows: rows)
                    for row in [rows.lowerBound, rows.upperBound - 1] {
                        region.fill(palette.missingOutline, columns: tint, rows: row..<row + 1)
                    }
                }
            }
            fillRun()
            region.fill(palette.lane, columns: gap..<end, rows: rows)
            for bar in bars[firstBar...] {
                region.fill(palette.bar, columns: bar.columns, rows: bar.top..<bar.top + barRows)
            }
        }
        /// The waveform of the columns `range` of `clip`.
        func drawWaveform(
            _ clip: Clip, _ track: Track, _ range: Range<Int>, bottom: Int, chip: (columns: Range<Int>, bottom: Int)?,
            layerGains: ArraySlice<Double>?
        ) {
            let from = Double((clip.offset - clip.start).count) + Double(range.lowerBound) * pixelFrames
            switch inputs.peaks[clip.file] {
            case .ready(let peaks):
                resize(range.count)
                peaks.fill(&values, from: from, step: pixelFrames)
            case .unavailable: return
            case .computing, nil:
                // A take file before its peaks: the live peaks of its take (live take view), in
                // live frames, so the columns equal the last live draw.
                guard let (peaks, anchor) = live.files[clip.file] else { return }
                resize(range.count)
                peaks.fill(&values, from: from + Double((anchor - peaks.origin).count), step: pixelFrames)
            }
            // The fades as the clip sounds: a crossfade is the fade of its edge (decision 0036).
            // Most clips have no crossfade and skip the lane lookup of the sounding clip.
            let sounding =
                clip.crossfades == .zero
                ? nil : track.clips.index(holding: clip.start).map(track.clips.sounding(at:))
            let (clipFades, curves, length, start) =
                sounding.map { ($0.clip.fades, $0.curves, $0.clip.length, $0.clip.start) }
                ?? (clip.fades, Fades.Curves.sine, clip.length, clip.start)
            let fades =
                clipFades == .zero
                ? nil
                : ColumnFades(
                    fades: clipFades, curves: curves, length: length,
                    first: Double(range.lowerBound) * pixelFrames - Double(start.count),
                    step: pixelFrames, line: Double(clip.length.count) / inputs.scale.framesPerPoint >= 12)
            drawColumns(
                range, waveform: inputs.range, gain: clip.gain.dB + track.gain.dB, fades: fades,
                layerGains: layerGains, bottom: bottom, chip: chip, palette, into: region)
        }
        crossfaded.removeAll(keepingCapacity: true)
        layerGains.removeAll(keepingCapacity: true)
        var chips: [ClipID: (columns: Range<Int>, bottom: Int)] = [:]
        for label in labels { if let clip = label.clip { chips[clip] = label.cut(scale: scale) } }
        for lane in drawn {
            let track = tracks[lane]
            let bottom = window.rows(of: lane..<lane + 1).upperBound - 1
            let inView = track.clips.clips(overlapping: visible)
            collectCrossfades(inView, of: track.clips, lane: lane)
            // The columns whose first frame is in the clip: each column draws one waveform. A clip
            // under one column can hold none (at fit zoom, 2,000 clips per lane drew each column
            // about 1.7 times). Each part of a masked region draws as a region of its own columns.
            for clip in inView {
                let (left, right) = (column(clip.start).rounded(.up), column(clip.end).rounded(.up))
                let columns = clamped(left)..<clamped(right)
                // The layer gains of all the columns of the clip in the rect, as the gain line reads them.
                var gains: ArraySlice<Double>?
                if clip.hasLayers && !columns.isEmpty {
                    gains = columnGains(
                        of: clip, columns, in: Int(left)..<Int(right), pixelFrames,
                        margin: window.pixels.columns.count)
                    layerGains[clip.id] = gains
                }
                region.forEachPart(of: columns) { range in
                    let part = gains.map { $0.dropFirst(range.lowerBound - columns.lowerBound).prefix(range.count) }
                    drawWaveform(clip, track, range, bottom: bottom, chip: chips[clip.id], layerGains: part)
                }
            }
        }
        if !displaying { endEvent() }
        // The fade line of each crossfade half outside its box, over the waveform of the neighbor
        // (decision 0036).
        for (lane, clip) in crossfaded { drawCrossfadeLines(clip, tracks[lane], lane, geometry, palette, into: region) }
        // The bar edge, over the waveform, under the controls and the joins.
        for bar in bars {
            region.fill(palette.barEdge, columns: bar.columns, rows: bar.top + barRows - 1..<bar.top + barRows)
        }
        // The gain line and the fade handles (run 11b-1) after the waveforms, from the `Clip` and
        // `Track` fields only: a clip with no peaks or missing media draws them too, as the hit
        // test finds them.
        for lane in drawn {
            let track = tracks[lane]
            let inView = track.clips.clips(overlapping: visible)
            for clip in inView where geometry.box(of: clip, lane: lane).width >= LaneGeometry.controlsWidth {
                drawControls(clip, track, lane, geometry, palette, layerGains: layerGains[clip.id], into: region)
            }
            drawJoins(inView, of: track.clips, lane: lane, geometry, palette, into: region)
        }
        if let take = live.take {
            drawLive(take, inputs, take.finalizing ? palette : palette.live, labels: labels, into: region)
        }

        if let selection = inputs.marks.selection(in: inputs.session) {
            let band =
                Int(
                    column(selection.range.lowerBound).rounded(.up))..<Int(
                    column(selection.range.upperBound).rounded(.up))
            for lane in drawn where selection.tracks.contains(tracks[lane].id) {
                region.blend(columns: band, rows: window.rows(of: lane..<lane + 1), palette.selected)
            }
        }
        // A clip set: a tint and a 2 pt outline on each box of the set, by clip ID, so the look
        // follows the clips in a drag preview (decision 0038).
        if case .clips(let set) = inputs.selection {
            let width = Int((2 * scale).rounded())
            for lane in drawn {
                let rows = window.rows(of: lane..<lane + 1)
                for clip in tracks[lane].clips.clips(overlapping: visible) where set.ids.contains(clip.id) {
                    let (left, right) = (Int(column(clip.start).rounded(.down)), Int(column(clip.end).rounded(.up)))
                    region.blend(columns: left..<right, rows: rows, palette.tinted)
                    for columns in [left..<left + width, right - width..<right] {
                        region.fill(palette.outline, columns: columns, rows: rows)
                    }
                    for edge in [rows.lowerBound..<rows.lowerBound + width, rows.upperBound - width..<rows.upperBound] {
                        region.fill(palette.outline, columns: left..<right, rows: edge)
                    }
                }
            }
        }
        // A line crosses every lane; the region keeps it to the rect.
        func line(_ frame: Frames?, _ color: UInt32) {
            guard let frame else { return }
            region.span(color, column: Self.lineColumn(frame, geometry, scale: scale), rows: window.pixels.rows)
        }
        for marker in inputs.session.markers.values {
            line(marker.position, marker.kind == .marker ? palette.marker : palette.chapter)
        }
        line(inputs.marks.inPoint, palette.inPoint)
        line(inputs.marks.outPoint, palette.outPoint)
    }

    /// The one pixel column of the line of a marker, a chapter, or a mark at `frame`.
    static func lineColumn(_ frame: Frames, _ geometry: LaneGeometry, scale: Double) -> Int {
        Int((geometry.x(of: frame) * scale).rounded(.down))
    }

    /// Gives `values` `count` columns. `fill` sets every column, so only the count matters. The
    /// array keeps its memory: at fit zoom the count changes between 1 and 2 at almost every clip.
    func resize(_ count: Int) {
        guard values.count != count else { return }
        values.removeAll(keepingCapacity: true)
        values.append(contentsOf: repeatElement(PeakColumn.zero, count: count))
    }

    /// The one waveform draw of the final and the live columns: `values` from the column
    /// `range.lowerBound`, rectified on the dB scale of `waveform` with `gain`, light peaks over dark
    /// RMS, up from the row `bottom`. A column in a fade of `fades` adds 20 log10 of its fade factor,
    /// and a column of a clip with gain layers adds its gain of `layerGains`, one per column of
    /// `range` (`columnGains`); the fade line of such a clip stays under the top of the box (`lineClamp`).
    /// `chip`: the columns of a label chip and the row under its bottom; the peak and RMS spans of
    /// those columns start there, so the bar shows under the text. The fade line still draws.
    func drawColumns(
        _ range: Range<Int>, waveform: WaveformRange, gain: Double, fades: ColumnFades? = nil,
        layerGains: ArraySlice<Double>? = nil, bottom: Int, chip: (columns: Range<Int>, bottom: Int)? = nil,
        _ palette: LanePalette, into region: borrowing PixelRegion
    ) {
        let laneRows = region.window.laneRows
        let clamp = layerGains == nil ? 0 : Self.lineClamp(scale: region.window.scale)
        values.withUnsafeBufferPointer { values in
            Self.decibels.withUnsafeBufferPointer { decibels in
                func height(decibels decibel: Double, _ gain: Double) -> Int {
                    Int((waveform.fraction(dB: decibel + gain) * Double(laneRows)).rounded())
                }
                func height(_ value: UInt16, _ gain: Double) -> Int {
                    value > 0 ? height(decibels: decibels[Int(value)], gain) : 0
                }
                var index = 0
                while index < values.count {
                    let column = range.lowerBound + index
                    // Only a column in a fade computes a factor; 20 log10(0) is -infinity, height 0.
                    let factor = fades?.factor(index)
                    var columnGain = factor.map { gain + 20 * log10($0) } ?? gain
                    if let layerGains { columnGain += layerGains[layerGains.startIndex + index] }
                    let peak = height(values[index].peak, columnGain)
                    // A cache file can hold an RMS over its peak; the span never inverts.
                    let rms = min(height(values[index].rms, columnGain), peak)
                    // A column span is a strided fill: one call, not one Swift step per pixel.
                    // The start of the spans: the row under the chip in a chip column.
                    let floor = chip.map { $0.columns.contains(column) ? $0.bottom : 0 } ?? 0
                    let (top, middle) = (max(bottom - peak + 1, floor), max(bottom - rms + 1, floor))
                    region.span(palette.peak, column: column, rows: top..<middle)
                    region.span(palette.rms, column: column, rows: middle..<bottom + 1)
                    if factor != nil, fades?.line == true {
                        let row = Self.lineRow(
                            columnGain, waveform: waveform, bottom: bottom, laneRows: laneRows, clamp: clamp)
                        region.span(palette.label, column: column, rows: row..<row + 1)
                    }
                    index += 1
                }
            }
        }
    }
}
