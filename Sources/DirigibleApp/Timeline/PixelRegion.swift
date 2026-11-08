import Accelerate
import CoreGraphics
import Foundation

/// The writable pixels of a draw (plan gate 1 item 5): a window of document pixels over the memory
/// of a locked surface, or of a test. Every write keeps to `rect`, the rect of the draw, so a draw
/// never changes a pixel outside it: the selection band never halves a copied pixel. The pointer is
/// private, and the value is not copyable: it is lent into a closure and does not escape it. The
/// `CGContext` of `withContext` must not escape its closure either; that is a rule, not a type.
/// A region with a mask writes only the mask columns of `rect`: one draw of the moved marker
/// lines of a still band (decision 0037), with one setup for all of them.
struct PixelRegion: ~Copyable {
    private let base: UnsafeMutableRawPointer
    private let bytesPerRow: Int
    let window: LaneWindow
    /// The pixels that this draw can write, in the window.
    let rect: PixelRect
    /// The columns of `rect` that this draw writes: sorted, apart, not empty. Nil: all of them.
    let mask: [Range<Int>]?

    /// `base` is the pixel of the first column and row of `window`. `mask` can be in any order.
    init(
        base: UnsafeMutableRawPointer, bytesPerRow: Int, window: LaneWindow, rect: PixelRect,
        mask: [Range<Int>]? = nil
    ) {
        (self.base, self.bytesPerRow, self.window) = (base, bytesPerRow, window)
        let rect = rect.intersection(window.pixels)
        let mask = mask.map { parts in
            parts.map { $0.clamped(to: rect.columns) }.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
                .reduce(into: [Range<Int>]()) { merged, next in
                    if let last = merged.last, next.lowerBound <= last.upperBound {
                        merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, next.upperBound)
                    } else {
                        merged.append(next)
                    }
                }
        }
        (self.rect, self.mask) = (mask?.isEmpty == true ? .empty : rect, mask)
    }

    /// Calls `body` with each part of `columns` that this draw writes, from left to right.
    func forEachPart(of columns: Range<Int>, _ body: (Range<Int>) -> Void) {
        let columns = columns.clamped(to: rect.columns)
        guard !columns.isEmpty else { return }
        guard let mask else { return body(columns) }
        var index = firstPart(after: columns.lowerBound, in: mask)
        while index < mask.count, mask[index].lowerBound < columns.upperBound {
            body(mask[index].clamped(to: columns))
            index += 1
        }
    }

    /// The index of the first part of `mask` that ends after `column`.
    private func firstPart(after column: Int, in mask: [Range<Int>]) -> Int {
        var (low, high) = (0, mask.count)
        while low < high {
            let middle = (low + high) / 2
            if mask[middle].upperBound <= column { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func address(_ column: Int, _ row: Int) -> UnsafeMutablePointer<UInt32> {
        (base + (row - window.pixels.rows.lowerBound) * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            + (column - window.pixels.columns.lowerBound)
    }

    /// Sets `rows` of `column` to `color`. `vDSP_vfill` moves the 32 bits of the pixel as a float,
    /// with no arithmetic, so the bits stay the same.
    func span(_ color: UInt32, column: Int, rows: Range<Int>) {
        let rows = rows.clamped(to: rect.rows)
        guard rect.columns.contains(column), !rows.isEmpty else { return }
        if let mask {
            let index = firstPart(after: column, in: mask)
            guard index < mask.count, mask[index].contains(column) else { return }
        }
        fillColumn(color, column, rows)
    }

    private func fillColumn(_ color: UInt32, _ column: Int, _ rows: Range<Int>) {
        var value = Float(bitPattern: color)
        address(column, rows.lowerBound).withMemoryRebound(to: Float.self, capacity: 1) {
            vDSP_vfill(&value, $0, vDSP_Stride(bytesPerRow / 4), vDSP_Length(rows.count))
        }
    }

    /// A part of one column is one strided fill, not one `memset_pattern4` per row.
    func fill(_ color: UInt32, columns: Range<Int>, rows: Range<Int>) {
        let rows = rows.clamped(to: rect.rows)
        guard !rows.isEmpty else { return }
        forEachPart(of: columns) { part in
            if part.count == 1 { return fillColumn(color, part.lowerBound, rows) }
            var pattern = color
            for row in rows { memset_pattern4(address(part.lowerBound, row), &pattern, part.count * 4) }
        }
    }

    /// Each pixel through `transform`: the selection band (`LanePalette.selected`) and the tint of
    /// a selected clip (`LanePalette.tinted`). Each transform is a pure function of the pixel, and a
    /// row has long runs of one color, so the result of the last pixel is used again for an equal
    /// pixel (the Command-F bench spent 13 % of its timed span in this loop).
    func blend(columns: Range<Int>, rows: Range<Int>, _ transform: (UInt32) -> UInt32) {
        let rows = rows.clamped(to: rect.rows)
        var (last, result): (UInt32, UInt32) = (0, transform(0))
        forEachPart(of: columns) { part in
            for row in rows {
                let pixels = address(part.lowerBound, row)
                for index in 0..<part.count {
                    if pixels[index] != last { (last, result) = (pixels[index], transform(pixels[index])) }
                    pixels[index] = result
                }
            }
        }
    }

    /// A context over the window in flipped document points, for each area of `areas` (document
    /// points) in turn: `body` gets the index of the area, with the context clipped to the pixels
    /// of this draw in the columns of that area, so a label draws only over the pixels of this draw
    /// (plan gate 1 item 3). No call for an area where this draw has no column. Each clip holds
    /// only the mask parts of its area: text through a clip of every mask part cost 3 times the text.
    /// With no mask, one clip to `rect` serves all areas, with no clip per area.
    func withContext(in areas: [CGRect], _ body: (CGContext, Int) -> Void) {
        let scale = window.scale
        var context: CGContext?
        for (index, area) in areas.enumerated() {
            let columns = Int((area.minX * scale).rounded(.down))..<Int((area.maxX * scale).rounded(.up))
            var clip: [CGRect] = []
            if mask == nil {
                guard columns.overlaps(rect.columns) else { continue }
            } else {
                forEachPart(of: columns) { clip.append(window.points(of: PixelRect(columns: $0, rows: rect.rows))) }
                guard !clip.isEmpty else { continue }
            }
            if context == nil {
                context = makeContext()
                if mask == nil { context?.clip(to: window.points(of: rect)) }
            }
            guard let context else { return }
            context.saveGState()
            if !clip.isEmpty { context.clip(to: clip) }
            body(context, index)
            context.restoreGState()
        }
    }

    private func makeContext() -> CGContext? {
        let context = CGContext(
            data: base, width: window.pixels.columns.count, height: window.pixels.rows.count, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: Self.space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let scale = window.scale
        context?.translateBy(x: 0, y: Double(window.pixels.rows.count))
        context?.scaleBy(x: scale, y: -scale)
        context?.translateBy(
            x: -Double(window.pixels.columns.lowerBound) / scale, y: -Double(window.pixels.rows.lowerBound) / scale)
        return context
    }

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
}
