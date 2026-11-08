import Foundation

@testable import DirigibleApp

/// Pixels that a test owns: the lanes of `window`, drawn through a `PixelRegion` as the view draws
/// them into a surface. Each pixel starts as `fill`.
final class OwnedPixels {
    let window: LaneWindow
    private let bytesPerRow: Int
    private let memory: UnsafeMutableRawPointer

    init(_ window: LaneWindow, fill: UInt32 = 0) {
        self.window = window
        // An odd count of 64-byte lines per row, as a surface has.
        bytesPerRow = ((window.pixels.columns.count + 15) / 16 | 1) * 64
        let count = bytesPerRow * window.pixels.rows.count
        memory = .allocate(byteCount: count, alignment: 64)
        var pattern = fill
        memset_pattern4(memory, &pattern, count)
    }

    deinit { memory.deallocate() }

    /// Lends a region of `rect` (all of the window by default), with the column mask `mask`.
    func draw(_ rect: PixelRect? = nil, mask: [Range<Int>]? = nil, _ body: (borrowing PixelRegion) -> Void) {
        body(
            PixelRegion(
                base: memory, bytesPerRow: bytesPerRow, window: window, rect: rect ?? window.pixels, mask: mask))
    }

    /// The pixel at a document column and row.
    func pixel(_ column: Int, _ row: Int) -> UInt32 { self.row(row)[column - window.pixels.columns.lowerBound] }

    /// The pixels of a document row, one per column of the window.
    func row(_ row: Int) -> [UInt32] {
        precondition(
            window.pixels.rows.contains(row), "the row \(row) is in the rows \(window.pixels.rows) of the window")
        let start = (memory + (row - window.pixels.rows.lowerBound) * bytesPerRow).assumingMemoryBound(to: UInt32.self)
        return Array(UnsafeBufferPointer(start: start, count: window.pixels.columns.count))
    }

    /// The pixels of the lanes of `inputs` in `window`, rendered as the view renders them: a new
    /// renderer, then the labels.
    @MainActor static func render(
        _ inputs: LaneInputs, _ window: LaneWindow, _ palette: LanePalette = .light, live: LiveLanes = LiveLanes()
    ) -> OwnedPixels {
        let pixels = OwnedPixels(window)
        pixels.draw { region in
            TimelineDocumentView.drawLanes(LaneRenderer(), inputs, palette, live: live, into: region)
        }
        return pixels
    }
}

/// The window of document points `x ..< x + width` of all lanes of `inputs` at `scale`.
func laneWindow(_ inputs: LaneInputs, x: Double = 0, width: Double, scale: Double = 1) -> LaneWindow? {
    let rect = CGRect(x: x, y: 0, width: width, height: Double(inputs.session.tracks.count) * inputs.laneHeight)
    return LaneWindow(
        view: rect, bounds: rect, laneHeight: inputs.laneHeight, lanes: inputs.session.tracks.count, scale: scale,
        room: width)
}
