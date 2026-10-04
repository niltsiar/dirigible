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

    /// The one point and frame conversion of the lanes (decision 0020).
    var geometry: LaneGeometry? { LaneGeometry(scale: scale, laneHeight: laneHeight) }
    /// The range that draws its band and lines; no Marks for a clip set (decision 0038).
    var marks: Marks { selection.marks ?? Marks() }
}

/// The lane colors as pixels: 0xAARRGGBB in a little-endian word (BGRA in memory).
struct LanePalette: Equatable {
    var lane, clip, peak, rms, missing, missingOutline, label, marker, chapter, inPoint, outPoint: UInt32
    /// The accent color that the selection band blends toward; nil: the band is half as bright.
    var accent: UInt32?
    /// The system accent color: the outline of a selected clip, and the color of its tint
    /// (decision 0038). `light` has the default blue; `pick` gives the accent of the system.
    var outline: UInt32 = 0xFF00_7AFF

    static let light = LanePalette(
        lane: 0xFFE8_ECF2, clip: 0xFFC4_DAF5, peak: 0xFF7A_A7E0, rms: 0xFF1F_4F9E, missing: 0xFFF4_C4C4,
        missingOutline: 0xFFC8_2020, label: 0xFF26_2626, marker: 0xFFF2_8C1A, chapter: 0xFF8E_44AD,
        inPoint: 0xFF2E_A043, outPoint: 0xFFE0_3A3A)

    /// The lanes in light mode with the accent color of the system.
    static func light(accent: UInt32) -> LanePalette {
        var palette = light
        palette.outline = accent
        return palette
    }

    /// The lanes in Dark Mode (ux-visual-perf section 1). The label on the clip has a contrast of
    /// about 8.7:1. The lines keep their light colors.
    static func dark(accent: UInt32) -> LanePalette {
        var palette = light
        (palette.lane, palette.clip, palette.peak, palette.rms) = (0xFF1E_1F22, 0xFF2C_3E57, 0xFF6E_9FE0, 0xFFA9_C8F2)
        (palette.missing, palette.missingOutline, palette.label) = (0xFF4A_2427, 0xFFFF_6961, 0xFFE6_E6E6)
        (palette.accent, palette.outline) = (accent, accent)
        return palette
    }

    /// A pixel of a selected clip box: each channel 25 % toward the outline color, rounded to the
    /// nearest (decision 0038).
    func tinted(_ pixel: UInt32) -> UInt32 {
        var result: UInt32 = 0xFF00_0000
        for shift: UInt32 in [0, 8, 16] {
            let (c, o) = (Int((pixel >> shift) & 0xFF), Int((outline >> shift) & 0xFF))
            let step = o - c
            result |= UInt32(c + (step + (step < 0 ? -2 : 2)) / 4) << shift
        }
        return result
    }

    /// A pixel under the selection band: half as bright, or in Dark Mode each channel 30 % toward
    /// the accent, rounded to the nearest.
    func selected(_ pixel: UInt32) -> UInt32 {
        guard let accent else { return 0xFF00_0000 | ((pixel >> 1) & 0x007F_7F7F) }
        var result: UInt32 = 0xFF00_0000
        for shift: UInt32 in [0, 8, 16] {
            let (c, a) = (Int((pixel >> shift) & 0xFF), Int((accent >> shift) & 0xFF))
            let step = (a - c) * 3
            result |= UInt32(c + (step + (step < 0 ? -5 : 5)) / 10) << shift
        }
        return result
    }

    /// The label color for AppKit text.
    var labelColor: NSColor {
        func channel(_ shift: UInt32) -> Double { Double((label >> shift) & 0xFF) / 255 }
        return NSColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }
}

/// Draws the lanes into a caller's pixels (decisions 0017 and 0022, probe D2): a background pattern
/// per row, then the clip boxes, the missing-media tint, and the waveform as column spans, rectified
/// on a -60 dB to 0 dB scale, light peaks over dark RMS, with clip gain plus track gain and the
/// fades of decision 0035, and a fade line in clip boxes of 12 pt or more. Then the fade lines of
/// the crossfade halves outside the boxes (decision 0036), the gain lines and handles, the
/// selection band and the marker, chapter, in, and out lines. One per document view, on the main
/// thread. It writes every pixel of the rect of the region, and the region refuses every pixel
/// outside it. Each edge rounds in absolute document pixels, so two partial draws agree with one
/// full draw on each pixel. It keeps no pixel state. A drag event redraws only the columns that
/// `changedFrames` gives, so each Session value drawn here needs a compare there (decision 0020,
/// the invariant).
final class LaneRenderer {
    /// The columns of one clip, reused.
    var values: [PeakColumn] = []
    /// The clips with a crossfade that the fade-line pass draws, with their lanes, reused. The
    /// waveform pass collects them, so a draw with no crossfade scans no lane again.
    var crossfaded: [(lane: Int, clip: Clip)] = []

    /// 20 log10(v / 65535) for each magnitude v.
    private static let decibels: [Double] = (0...65535).map { 20 * log10(Double($0) / 65535) }

    /// Draws the rect of `region`: the lanes that its rows cross, in its columns. Then the live
    /// take over the clips.
    func draw(
        _ inputs: LaneInputs, _ palette: LanePalette, live: LiveLanes = LiveLanes(), into region: borrowing PixelRegion
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
        for lane in drawn {
            let track = tracks[lane]
            let rows = window.rows(of: lane..<lane + 1)
            // Each pixel gets one background: the lane color only in the gaps between the clips.
            var gap = first
            // The columns of adjacent clips that are not filled yet: one fill for a run of clips,
            // not one per clip (2,000 clips of 1 or 2 columns took 14 ms at fit zoom).
            var run: Range<Int>?
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
        }
        crossfaded.removeAll(keepingCapacity: true)
        for lane in drawn {
            let track = tracks[lane]
            let bottom = window.rows(of: lane..<lane + 1).upperBound - 1
            let inView = track.clips.clips(overlapping: visible)
            collectCrossfades(inView, of: track.clips, lane: lane)
            for clip in inView {
                // The columns whose first frame is in the clip: each column draws one waveform. A
                // clip under one column can hold none (at fit zoom, 2,000 clips per lane drew each
                // column about 1.7 times).
                let range = clamped(column(clip.start).rounded(.up))..<clamped(column(clip.end).rounded(.up))
                guard !range.isEmpty else { continue }
                let from = Double((clip.offset - clip.start).count) + Double(range.lowerBound) * pixelFrames
                switch inputs.peaks[clip.file] {
                case .ready(let peaks):
                    resize(range.count)
                    peaks.fill(&values, from: from, step: pixelFrames)
                case .unavailable: continue
                case .computing, nil:
                    // A take file before its peaks: the live peaks of its take (live take view), in
                    // live frames, so the columns equal the last live draw.
                    guard let (peaks, anchor) = live.files[clip.file] else { continue }
                    resize(range.count)
                    peaks.fill(&values, from: from + Double((anchor - peaks.origin).count), step: pixelFrames)
                }
                // The fades as the clip sounds: a crossfade is the fade of its edge (decision 0036).
                // Most clips have no crossfade and skip the sounding copy.
                let sounding = clip.crossfades == .zero ? nil : clip.sounding
                let (clipFades, length, start) =
                    sounding.map { ($0.fades, $0.length, $0.start) } ?? (clip.fades, clip.length, clip.start)
                let fades =
                    clipFades == .zero
                    ? nil
                    : ColumnFades(
                        fades: clipFades, length: length,
                        first: Double(range.lowerBound) * pixelFrames - Double(start.count),
                        step: pixelFrames, line: Double(clip.length.count) / inputs.scale.framesPerPoint >= 12)
                drawColumns(
                    range, gain: clip.gain.dB + track.gain.dB, fades: fades, bottom: bottom, palette, into: region)
            }
        }
        // The fade line of each crossfade half outside its box, over the waveform of the neighbor
        // (decision 0036).
        for (lane, clip) in crossfaded { drawCrossfadeLines(clip, tracks[lane], lane, geometry, palette, into: region) }
        // The gain line and the fade handles (run 11b-1) after the waveforms, from the `Clip` and
        // `Track` fields only: a clip with no peaks or missing media draws them too, as the hit
        // test finds them.
        for lane in drawn {
            let track = tracks[lane]
            for clip in track.clips.clips(overlapping: visible)
            where geometry.box(of: clip, lane: lane).width >= LaneGeometry.controlsWidth {
                drawControls(clip, track, lane, geometry, palette, into: region)
            }
        }
        if let take = live.take { drawLive(take, inputs, palette, into: region) }

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
            region.span(color, column: Int(column(frame).rounded(.down)), rows: window.pixels.rows)
        }
        for marker in inputs.session.markers.values {
            line(marker.position, marker.kind == .marker ? palette.marker : palette.chapter)
        }
        line(inputs.marks.inPoint, palette.inPoint)
        line(inputs.marks.outPoint, palette.outPoint)
    }

    /// Gives `values` `count` columns. `fill` sets every column, so only the count matters. The
    /// array keeps its memory: at fit zoom the count changes between 1 and 2 at almost every clip.
    func resize(_ count: Int) {
        guard values.count != count else { return }
        values.removeAll(keepingCapacity: true)
        values.append(contentsOf: repeatElement(PeakColumn.zero, count: count))
    }

    /// The one waveform draw of the final and the live columns: `values` from the column
    /// `range.lowerBound`, rectified on a -60 dB to 0 dB scale with `gain`, light peaks over dark
    /// RMS, up from the row `bottom`. A column in a fade of `fades` adds 20 log10 of its fade factor.
    func drawColumns(
        _ range: Range<Int>, gain: Double, fades: ColumnFades? = nil, bottom: Int, _ palette: LanePalette,
        into region: borrowing PixelRegion
    ) {
        let laneRows = region.window.laneRows
        values.withUnsafeBufferPointer { values in
            Self.decibels.withUnsafeBufferPointer { decibels in
                func height(decibels decibel: Double, _ gain: Double) -> Int {
                    let fraction = (decibel + gain + 60) / 60
                    return fraction <= 0 ? 0 : Int(((fraction < 1 ? fraction : 1) * Double(laneRows)).rounded())
                }
                func height(_ value: UInt16, _ gain: Double) -> Int {
                    value > 0 ? height(decibels: decibels[Int(value)], gain) : 0
                }
                var index = 0
                while index < values.count {
                    let column = range.lowerBound + index
                    // Only a column in a fade computes a factor; 20 log10(0) is -infinity, height 0.
                    let factor = fades?.factor(index)
                    let columnGain = factor.map { gain + 20 * log10($0) } ?? gain
                    let peak = height(values[index].peak, columnGain)
                    // A cache file can hold an RMS over its peak; the span never inverts.
                    let rms = min(height(values[index].rms, columnGain), peak)
                    // A column span is a strided fill: one call, not one Swift step per pixel.
                    region.span(palette.peak, column: column, rows: bottom - peak + 1..<bottom - rms + 1)
                    region.span(palette.rms, column: column, rows: bottom - rms + 1..<bottom + 1)
                    if factor != nil, fades?.line == true {
                        let row = Self.lineRow(columnGain, bottom: bottom, laneRows: laneRows)
                        region.span(palette.label, column: column, rows: row..<row + 1)
                    }
                    index += 1
                }
            }
        }
    }
}

/// The fades of one clip in the columns of a draw (decision 0035): the clip frame of the first
/// column, and the frames per column.
struct ColumnFades {
    let fades: Fades
    let length: Frames
    let first: Double
    let step: Double
    /// A 1 px fade line, only in clip boxes of 12 pt or more wide (0035).
    let line: Bool

    /// The maximum of the fade factor over the frames of column `index` (plan gate F2): the fade-in
    /// at min(k + step, I), the fade-out at max(k, N - O). Nil when that maximum is 1, so a column
    /// that holds a fade end costs nothing: at fit zoom almost every column holds one (bench C25).
    func factor(_ index: Int) -> Double? {
        // A rounded column can start at the clip end; the curve takes a frame of the clip.
        let k = min(max(0, Int((first + Double(index) * step).rounded(.down))), length.count - 1)
        let end = k + Int(step.rounded(.up))
        let rising = end < fades.fadeIn.count
        let falling = fades.fadeOut > .zero && k > length.count - fades.fadeOut.count
        guard rising || falling else { return nil }
        var factor = 1.0
        if rising { factor *= fades.gain(at: Frames(end), length: length) }
        if falling { factor *= fades.gain(at: Frames(k), length: length) }
        return factor
    }
}
