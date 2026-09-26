import Accelerate
import CoreGraphics
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation

/// Every input that the lane pixels read (decision 0017), except the backing scale. The document
/// view redraws only when this value changes, so an input outside it never redraws.
struct LaneInputs: Equatable {
    var session: Session
    var peaks: [FileID: PeakState]
    var missingMedia: [FileID: MediaFault]
    var marks: Marks
    var scale: TimelineScale
    /// Points.
    var laneHeight: Double

    /// The one point and frame conversion of the lanes (decision 0020).
    var geometry: LaneGeometry? { LaneGeometry(scale: scale, laneHeight: laneHeight) }
}

/// The lane colors as pixels: 0xAARRGGBB in a little-endian word (BGRA in memory).
enum LaneColors {
    static let lane: UInt32 = 0xFFE8_ECF2
    static let clip: UInt32 = 0xFFC4_DAF5
    static let peak: UInt32 = 0xFF7A_A7E0
    static let rms: UInt32 = 0xFF1F_4F9E
    static let missing: UInt32 = 0xFFF4_C4C4
    static let missingOutline: UInt32 = 0xFFC8_2020
    static let marker: UInt32 = 0xFFF2_8C1A
    static let chapter: UInt32 = 0xFF8E_44AD
    static let inPoint: UInt32 = 0xFF2E_A043
    static let outPoint: UInt32 = 0xFFE0_3A3A

    /// A pixel under the selection band: half as bright.
    static func selected(_ pixel: UInt32) -> UInt32 { 0xFF00_0000 | ((pixel >> 1) & 0x007F_7F7F) }
}

/// Draws the lanes into own pixels (decision 0017, probe D2): a background pattern per row, then
/// the clip boxes, the missing-media tint, and the waveform as column spans, rectified on a
/// -60 dB to 0 dB scale, light peaks over dark RMS, with clip gain plus track gain. Then the
/// selection band and the marker, chapter, in, and out lines. One per document view, on the main
/// thread. Each image has its own buffer: a display-list context draws the image later, so a draw
/// never writes a buffer that an image holds (timeline-scroll symptom 1). A drag event redraws only the
/// columns that `changedFrames` gives, so each Session value drawn here needs a compare there
/// (decision 0020, the invariant).
final class LaneRenderer {
    private(set) var columns = 0
    private(set) var rows = 0
    /// Pixels per row: `columns` rounded up to an odd count of 64-byte cache lines.
    private var rowLength = 0
    /// The buffer of the last draw.
    private var buffer: PixelBuffer?
    private var pixels: UnsafeMutablePointer<UInt32>? { buffer?.pixels }
    /// The buffers that an image can hold, the last one, and at most three free buffers to reuse.
    private var pool: [PixelBuffer] = []
    /// The columns of one clip, reused.
    private var values: [PeakColumn] = []

    /// The bitmap memory, so a test can see which draws reuse it.
    var bufferAddress: UnsafeMutableRawPointer? { buffer.map { UnsafeMutableRawPointer($0.pixels) } }

    /// The buffers that an image can still hold, with the buffer of the last draw, and their bytes.
    func liveBuffers() -> (count: Int, bytes: Int) {
        let live = pool.indices.filter { !isKnownUniquelyReferenced(&pool[$0]) }
        return (live.count, live.reduce(0) { $0 + pool[$1].capacity * 4 })
    }

    /// The pixel of the last draw at `column` and `row` (row 0 is the top of lane 1).
    func pixel(_ column: Int, _ row: Int) -> UInt32 { pixels?[row * rowLength + column] ?? 0 }

    /// 20 log10(v / 65535) for each magnitude v.
    private static let decibels: [Double] = (0...65535).map { 20 * log10(Double($0) / 65535) }

    /// Draws the document points `x ..< x + width` of the lanes `lanes` (all by default) at `scale`
    /// pixels per point. Row 0 of the image is the top of the first of them.
    func draw(_ inputs: LaneInputs, x: Double, width: Double, scale: Double, lanes: Range<Int>? = nil) -> CGImage? {
        let laneRows = max(1, Int((inputs.laneHeight * scale).rounded()))
        let tracks = inputs.session.tracks
        let drawn = (lanes ?? tracks.indices).clamped(to: tracks.indices)
        prepare(columns: max(1, Int((width * scale).rounded())), rows: max(1, drawn.count * laneRows))
        guard let buffer, let geometry = inputs.geometry else { return nil }
        let pixels = buffer.pixels
        let pointFrames = inputs.scale.framesPerPoint
        let pixelFrames = pointFrames / scale
        let first = x * pointFrames
        /// The column of a timeline frame, not clamped: the x of `LaneGeometry`, so a clip draws
        /// where the hit test finds it.
        func column(_ frame: Frames) -> Double { (geometry.x(of: frame) - x) * scale }
        func clamped(_ value: Double) -> Int { Int(min(max(value, 0), Double(columns))) }
        let visible = Frames(Int(max(0, first)))..<Frames(Int(first + Double(columns) * pixelFrames) + 1)

        // First the boxes of every lane, then the waveforms, so a span that passes its lane shows.
        for lane in drawn {
            let track = tracks[lane]
            let top = (lane - drawn.lowerBound) * laneRows
            let bottom = top + laneRows - 1
            // Each pixel gets one background: the lane color only in the gaps between the clips.
            var gap = 0
            // The columns of adjacent clips that are not filled yet: one fill for a run of clips,
            // not one per clip (2,000 clips of 1 or 2 columns took 14 ms at fit zoom).
            var run: Range<Int>?
            func fillRun() {
                if let run { fill(LaneColors.clip, columns: run, rows: top...bottom) }
                run = nil
            }
            for clip in track.clips.clips(overlapping: visible) {
                let range = clamped(column(clip.start).rounded(.down))..<clamped(column(clip.end).rounded(.up))
                guard !range.isEmpty else { continue }
                if gap < range.lowerBound {
                    fillRun()
                    fill(LaneColors.lane, columns: gap..<range.lowerBound, rows: top...bottom)
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
                    fill(LaneColors.missing, columns: tint, rows: top...bottom)
                    for row in [top, bottom] { fill(LaneColors.missingOutline, columns: tint, rows: row...row) }
                }
            }
            fillRun()
            fill(LaneColors.lane, columns: gap..<columns, rows: top...bottom)
        }
        for lane in drawn {
            let track = tracks[lane]
            let bottom = (lane - drawn.lowerBound + 1) * laneRows - 1
            for clip in track.clips.clips(overlapping: visible) {
                // The columns whose first frame is in the clip: each column draws one waveform. A
                // clip under one column can hold none (at fit zoom, 2,000 clips per lane drew each
                // column about 1.7 times).
                let range = clamped(column(clip.start).rounded(.up))..<clamped(column(clip.end).rounded(.up))
                guard !range.isEmpty, case .ready(let peaks) = inputs.peaks[clip.file] else { continue }
                // `fill` sets every column, so only the count matters. The array keeps its memory:
                // at fit zoom the count changes between 1 and 2 at almost every clip.
                if values.count != range.count {
                    values.removeAll(keepingCapacity: true)
                    values.append(contentsOf: repeatElement(PeakColumn.zero, count: range.count))
                }
                let from = Double((clip.offset - clip.start).count) + first + Double(range.lowerBound) * pixelFrames
                peaks.fill(&values, from: from, step: pixelFrames)
                let gain = clip.gain.dB + track.gain.dB
                values.withUnsafeBufferPointer { values in
                    Self.decibels.withUnsafeBufferPointer { decibels in
                        func height(_ value: UInt16) -> Int {
                            guard value > 0 else { return 0 }
                            let fraction = (decibels[Int(value)] + gain + 60) / 60
                            return fraction <= 0 ? 0 : Int(((fraction < 1 ? fraction : 1) * Double(laneRows)).rounded())
                        }
                        var index = 0
                        while index < values.count {
                            let column = range.lowerBound + index
                            let peak = height(values[index].peak)
                            // A cache file can hold an RMS over its peak; the span never inverts.
                            let rms = min(height(values[index].rms), peak)
                            // A column span is a strided fill: one call, not one Swift step per pixel.
                            span(LaneColors.peak, column: column, rows: bottom - peak + 1..<bottom - rms + 1)
                            span(LaneColors.rms, column: column, rows: bottom - rms + 1..<bottom + 1)
                            index += 1
                        }
                    }
                }
            }
        }

        if let selection = inputs.marks.selection(in: inputs.session) {
            let band =
                clamped(
                    column(selection.range.lowerBound).rounded(.up))..<clamped(
                    column(selection.range.upperBound).rounded(.up))
            for lane in drawn where selection.tracks.contains(tracks[lane].id) {
                let top = (lane - drawn.lowerBound) * laneRows
                for row in top..<top + laneRows {
                    for column in band {
                        pixels[row * rowLength + column] = LaneColors.selected(pixels[row * rowLength + column])
                    }
                }
            }
        }
        func line(_ frame: Frames?, _ color: UInt32) {
            guard let frame else { return }
            let at = column(frame).rounded(.down)
            guard at >= 0, at < Double(columns) else { return }
            span(color, column: Int(at), rows: 0..<rows)
        }
        for marker in inputs.session.markers.values {
            line(marker.position, marker.kind == .marker ? LaneColors.marker : LaneColors.chapter)
        }
        line(inputs.marks.inPoint, LaneColors.inPoint)
        line(inputs.marks.outPoint, LaneColors.outPoint)
        return image(of: buffer)
    }

    /// An image over the buffer itself, with no copy (`makeImage()` copied 13.8 MB, about 4 ms at
    /// 2880 x 1200 px). The data provider holds the buffer until Core Graphics frees the image.
    private func image(of buffer: PixelBuffer) -> CGImage? {
        let bytes = rowLength * rows * 4
        // ponytail: a refused provider leaks its one reference; it needs a size that no draw gives.
        guard
            let provider = CGDataProvider(
                dataInfo: Unmanaged.passRetained(buffer).toOpaque(), data: buffer.pixels, size: bytes,
                releaseData: releasePixelBuffer)
        else { return nil }
        return CGImage(
            width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowLength * 4,
            space: Self.space,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Takes the buffer of a draw: the smallest free buffer of the pool that is large enough, else
    /// a new one. A buffer is free when only the pool holds it, so no image shows its pixels. It
    /// keeps three other free buffers. No zero fill: each draw writes every pixel of its image
    /// (`aReusedBufferShowsNoPixelOfTheLastDraw`).
    private func prepare(columns: Int, rows: Int) {
        // A column span writes one pixel per row. A row of 2880 px is 180 cache lines, so the rows
        // of a lane fell in 16 of the 64 L1 sets and evicted each other. An odd count uses all 64.
        let lines = (columns + 15) / 16
        rowLength = (lines | 1) * 16
        (self.columns, self.rows) = (columns, rows)
        let size = rowLength * rows
        buffer = nil
        let free = pool.indices.filter { isKnownUniquelyReferenced(&pool[$0]) }
        let fit = free.filter { pool[$0].capacity >= size }.min { pool[$0].capacity < pool[$1].capacity }
        let spare = free.filter { $0 != fit }.sorted { pool[$0].capacity > pool[$1].capacity }
        if let fit {
            buffer = pool[fit]
        } else {
            // The width of a page turn changes by a few columns, and a full draw is 20% wider, so a
            // buffer takes 25% more: a new buffer costs about 2 ms of page faults at 2880 x 1200 px.
            let new = PixelBuffer(capacity: size + size / 4)
            pool.append(new)
            buffer = new
        }
        for index in spare.dropFirst(3).sorted(by: >) { pool.remove(at: index) }
    }

    /// Sets `rows` of `column` to `color`. `vDSP_vfill` moves the 32 bits of the pixel as a float,
    /// with no arithmetic, so the bits stay the same.
    private func span(_ color: UInt32, column: Int, rows lines: Range<Int>) {
        guard let pixels, !lines.isEmpty else { return }
        var value = Float(bitPattern: color)
        (pixels + lines.lowerBound * rowLength + column).withMemoryRebound(to: Float.self, capacity: 1) {
            vDSP_vfill(&value, $0, vDSP_Stride(rowLength), vDSP_Length(lines.count))
        }
    }

    private func fill(_ color: UInt32, columns range: Range<Int>, rows lines: ClosedRange<Int>) {
        guard let pixels, !range.isEmpty else { return }
        var pattern = color
        for row in lines { memset_pattern4(pixels + row * rowLength + range.lowerBound, &pattern, range.count * 4) }
    }
}

/// The pixels of one lane image.
final class PixelBuffer {
    let pixels: UnsafeMutablePointer<UInt32>
    let capacity: Int

    init(capacity: Int) {
        pixels = .allocate(capacity: capacity)
        self.capacity = capacity
    }

    deinit { pixels.deallocate() }
}

/// The release of the data provider of a lane image. Core Graphics calls it on any thread when it
/// frees the image, so it is a C function outside every actor (AGENTS.md, concurrency).
private func releasePixelBuffer(_ info: UnsafeMutableRawPointer?, _ data: UnsafeRawPointer, _ size: Int) {
    guard let info else { return }
    Unmanaged<PixelBuffer>.fromOpaque(info).release()
}
