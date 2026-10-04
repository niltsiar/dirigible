import Accelerate
import CoreGraphics
import Foundation

/// The writable pixels of a draw (plan gate 1 item 5): a window of document pixels over the memory
/// of a locked surface, or of a test. Every write keeps to `rect`, the rect of the draw, so a draw
/// never changes a pixel outside it: the selection band never halves a copied pixel. The pointer is
/// private, and the value is not copyable: it is lent into a closure and does not escape it. The
/// `CGContext` of `withContext` must not escape its closure either; that is a rule, not a type.
struct PixelRegion: ~Copyable {
    private let base: UnsafeMutableRawPointer
    private let bytesPerRow: Int
    let window: LaneWindow
    /// The pixels that this draw writes, in the window.
    let rect: PixelRect

    /// `base` is the pixel of the first column and row of `window`.
    init(base: UnsafeMutableRawPointer, bytesPerRow: Int, window: LaneWindow, rect: PixelRect) {
        (self.base, self.bytesPerRow, self.window) = (base, bytesPerRow, window)
        self.rect = rect.intersection(window.pixels)
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
        var value = Float(bitPattern: color)
        address(column, rows.lowerBound).withMemoryRebound(to: Float.self, capacity: 1) {
            vDSP_vfill(&value, $0, vDSP_Stride(bytesPerRow / 4), vDSP_Length(rows.count))
        }
    }

    func fill(_ color: UInt32, columns: Range<Int>, rows: Range<Int>) {
        let (columns, rows) = (columns.clamped(to: rect.columns), rows.clamped(to: rect.rows))
        guard !columns.isEmpty else { return }
        var pattern = color
        for row in rows { memset_pattern4(address(columns.lowerBound, row), &pattern, columns.count * 4) }
    }

    /// Each pixel through `transform`: the selection band (`LanePalette.selected`) and the tint of
    /// a selected clip (`LanePalette.tinted`).
    func blend(columns: Range<Int>, rows: Range<Int>, _ transform: (UInt32) -> UInt32) {
        let (columns, rows) = (columns.clamped(to: rect.columns), rows.clamped(to: rect.rows))
        guard !columns.isEmpty else { return }
        for row in rows {
            let pixels = address(columns.lowerBound, row)
            for index in 0..<columns.count { pixels[index] = transform(pixels[index]) }
        }
    }

    /// A context over the window in flipped document points, clipped to `rect`: the labels draw
    /// only over the pixels of this draw (plan gate 1 item 3).
    func withContext(_ body: (CGContext) -> Void) {
        guard
            let context = CGContext(
                data: base, width: window.pixels.columns.count, height: window.pixels.rows.count, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: Self.space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        let scale = window.scale
        context.translateBy(x: 0, y: Double(window.pixels.rows.count))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(
            x: -Double(window.pixels.columns.lowerBound) / scale, y: -Double(window.pixels.rows.lowerBound) / scale)
        context.clip(to: window.points(of: rect))
        body(context)
    }

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
}
