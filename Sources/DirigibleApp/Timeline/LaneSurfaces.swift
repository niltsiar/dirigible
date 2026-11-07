import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import QuartzCore

/// Document pixels of the lanes: columns and rows at the backing scale. Row 0 is the top of lane 1.
struct PixelRect: Equatable {
    var columns: Range<Int>
    var rows: Range<Int>

    static let empty = PixelRect(columns: 0..<0, rows: 0..<0)

    var isEmpty: Bool { columns.isEmpty || rows.isEmpty }

    func intersection(_ other: PixelRect) -> PixelRect {
        let rect = PixelRect(columns: columns.clamped(to: other.columns), rows: rows.clamped(to: other.rows))
        return rect.isEmpty ? .empty : rect
    }

    /// The smallest rect that holds both. An empty rect adds nothing.
    func union(_ other: PixelRect) -> PixelRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return PixelRect(
            columns: min(
                columns.lowerBound, other.columns.lowerBound)..<max(columns.upperBound, other.columns.upperBound),
            rows: min(rows.lowerBound, other.rows.lowerBound)..<max(rows.upperBound, other.rows.upperBound))
    }
}

/// The size of each surface for one view size, backing scale, and lane height (plan gate 1 item 2):
/// ceil(max(clip view width, view width) x scale) + 1 columns, and (the lanes that fit in the view
/// height + 1) x the lane rows. A header drag changes the view width and keeps the clip view width,
/// so it keeps the capacity (decision 0023, "Surface capacity"). A scroll by a fraction of a point or across a lane edge keeps it, so it makes no surface.
struct SurfaceCapacity: Equatable {
    let columns: Int
    let rows: Int
    let scale: Double
    let laneRows: Int
}

/// The lanes in view, in pixels, and the one mapping between document points and lane pixels (plan
/// gate 1 item 7). The columns are the ones that the view crosses; the rows are the rows of the whole
/// lanes that the view crosses. The renderer, the labels, and `LaneSurfaces` read it.
struct LaneWindow: Equatable {
    let scale: Double
    /// The pixel rows of one lane.
    let laneRows: Int
    let pixels: PixelRect
    let capacity: SurfaceCapacity

    /// Nil when nothing is in view. `view` is the part of the lanes in view, in document points;
    /// `bounds` is the document. `lanes` is the track count. `room` is the width of the clip view,
    /// with the part under the track headers.
    init?(view: CGRect, bounds: CGRect, laneHeight: Double, lanes: Int, scale: Double, room: Double) {
        let shown = view.intersection(bounds)
        guard scale > 0, laneHeight > 0, lanes > 0, !shown.isNull, shown.width > 0, shown.height > 0 else { return nil }
        self.scale = scale
        // ponytail: the lane heights of the app are whole points, so a lane is whole pixels; a
        // fractional height would round each lane and move the rows from the points.
        laneRows = max(1, Int((laneHeight * scale).rounded()))
        let columns = Int((shown.minX * scale).rounded(.down))..<Int((shown.maxX * scale).rounded(.up))
        let rows = Int((shown.minY * scale).rounded(.down))..<Int((shown.maxY * scale).rounded(.up))
        let inView = (rows.lowerBound / laneRows..<(rows.upperBound + laneRows - 1) / laneRows).clamped(to: 0..<lanes)
        guard !inView.isEmpty else { return nil }
        pixels = PixelRect(columns: columns, rows: inView.lowerBound * laneRows..<inView.upperBound * laneRows)
        capacity = SurfaceCapacity(
            columns: Int((max(room, view.width) * scale).rounded(.up)) + 1,
            rows: (Int((view.height / laneHeight).rounded(.up)) + 1) * laneRows, scale: scale, laneRows: laneRows)
    }

    /// The lanes of the pixel rows `rows`.
    func lanes(of rows: Range<Int>) -> Range<Int> {
        rows.lowerBound / laneRows..<(rows.upperBound + laneRows - 1) / laneRows
    }

    /// The pixel rows of the lanes `lanes`.
    func rows(of lanes: Range<Int>) -> Range<Int> { lanes.lowerBound * laneRows..<lanes.upperBound * laneRows }

    /// The pixels in view of a rect of document points: its columns, and the rows of the whole lanes
    /// that it crosses. A rect out of view gives an empty rect.
    func pixels(of rect: CGRect) -> PixelRect {
        guard !rect.isNull, !rect.isEmpty else { return .empty }
        let c0 = max(Double(pixels.columns.lowerBound), (rect.minX * scale).rounded(.down))
        let c1 = min(Double(pixels.columns.upperBound), (rect.maxX * scale).rounded(.up))
        let r0 = max(Double(pixels.rows.lowerBound), (rect.minY * scale).rounded(.down))
        let r1 = min(Double(pixels.rows.upperBound), (rect.maxY * scale).rounded(.up))
        guard c0 < c1, r0 < r1 else { return .empty }
        return PixelRect(columns: Int(c0)..<Int(c1), rows: rows(of: lanes(of: Int(r0)..<Int(r1))))
    }

    /// The document points of a pixel rect.
    func points(of rect: PixelRect) -> CGRect {
        CGRect(
            x: Double(rect.columns.lowerBound) / scale, y: Double(rect.rows.lowerBound) / scale,
            width: Double(rect.columns.count) / scale, height: Double(rect.rows.count) / scale)
    }
}

/// The lanes as one layer of IOSurfaces written in place (decision 0022). Four slots of one
/// capacity. `show` is the only code that writes a surface (the test accessor `frontRow` only reads
/// the front): it writes only a slot that is not the layer contents and that the window server does
/// not use (`isInUse`) at the pick, and it lends its pixels only as a `PixelRegion` in a closure. So no write reaches the pixels on screen, and the
/// main actor never waits for the compositor (probe P1). A busy slot drops its surface and makes a
/// new one: the window server keeps its own reference until the window shows again (probe P3).
@MainActor final class LaneSurfaces {
    let layer = CALayer()

    private struct Slot {
        var surface: IOSurface?
        var window: LaneWindow?
        var commit = 0
    }

    /// Two slots take turns, and the others cover the frames that the compositor still shows (P1).
    /// With 3, a full draw of the lanes back to back found the picked slot in use at 42 of 120
    /// draws, and each made a new surface (p95 16.1 ms); with 4, at none (p95 11.3 ms).
    private var slots = [Slot](repeating: Slot(), count: 4)
    private var front: Int?
    private var commits = 0
    /// The rect that each of the last commits drew, one fewer than the slots. The pick takes the
    /// oldest slot, so the commits after the commit of any picked slot are all here.
    private var history: [(commit: Int, drawn: PixelRect)] = []

    /// Test support: writes of a surface in use at its lock, and writes of the layer contents.
    /// Both stay 0 by construction.
    private(set) var writesInUse = 0
    private(set) var writesOfFront = 0
    /// Test support: the surfaces made.
    private(set) var made = 0
    /// Test support: the rects that the last update copied from the front.
    private(set) var lastCopied: [PixelRect] = []
    /// Test support: the rects that the last update drew.
    private(set) var lastDrawn: [PixelRect] = []
    /// Test support: refuse each new surface, as a failed allocation does.
    var refusesNewSurfaces = false
    /// Test support: the updates that copied the later region by a shift (decision 0037).
    private(set) var shifted = 0

    /// A ripple drag (decision 0037): the columns at or after `column` show the front, each band of
    /// rows moved by its own `by` columns, and only the `strips` and the columns that a band shows
    /// at an edge draw. The bands cover the rows of the window.
    struct Shift: Equatable {
        struct Band: Equatable {
            let rows: Range<Int>
            let by: Int
        }
        let column: Int
        let bands: [Band]
        let strips: [PixelRect]
    }

    /// The result of `show`.
    enum Result: Equatable {
        /// `draw` got this rect, and the layer shows the new window.
        case drawn(PixelRect)
        /// Nothing changed: no commit.
        case unchanged
        /// No surface: the allocation of a new surface failed. The layer shows the old pixels.
        case refused
    }

    init() {
        layer.actions = [
            "contents": NSNull(), "contentsRect": NSNull(), "contentsScale": NSNull(), "position": NSNull(),
            "bounds": NSNull(),
        ]
    }

    /// The surfaces held, and their bytes.
    var count: Int { slots.filter { $0.surface != nil }.count }
    var bytes: Int { slots.reduce(0) { $0 + ($1.surface?.allocationSize ?? 0) } }
    /// The window that the layer shows.
    var shown: LaneWindow? { front.flatMap { slots[$0].window } }

    /// Shows `window`, with new pixels in `changed` (a rect in the window, from `pixels(of:)`) and in
    /// the part of the window that the window of the front does not hold. `draw` writes every pixel
    /// of the rect of its region. A `shift` applies only when the front shows the same window;
    /// else `changed` draws.
    func show(
        _ window: LaneWindow, changed: PixelRect, shift: Shift? = nil, draw: (borrowing PixelRegion) -> Void
    ) -> Result {
        let old = shown
        if changed.isEmpty, old == window { return .unchanged }
        let pick = slots.indices.filter { $0 != front }.min { slots[$0].commit < slots[$1].commit }!
        if let surface = slots[pick].surface, surface.isInUse || slots[pick].window?.capacity != window.capacity {
            slots[pick] = Slot()
        }
        if slots[pick].surface == nil, !refusesNewSurfaces, let new = Self.surface(window.capacity) {
            slots[pick].surface = new
            made += 1
        }
        guard let surface = slots[pick].surface else { return .refused }
        // The front has pixels to copy only at the same capacity: the same scale and lane rows.
        let from = old?.capacity == window.capacity ? old : nil
        let source = from == nil ? nil : front.flatMap { slots[$0].surface }
        let overlap = from?.pixels.intersection(window.pixels) ?? .empty
        let shift = from == window && source != nil ? shift : nil
        // With a shift, the later region is new for the history: the other slots copy it later.
        let all = window.pixels.columns
        let later = shift.map {
            PixelRect(
                columns: min(max($0.column, all.lowerBound), all.upperBound)..<all.upperBound, rows: window.pixels.rows)
        }
        let strips = (shift?.strips ?? []).map { $0.intersection(window.pixels) }.filter { !$0.isEmpty }
        let drawn =
            later.map { strips.reduce($0) { $0.union($1) } } ?? changed.union(Self.outside(overlap, of: window.pixels))
        // Buffer age: a slot that shows the same pixels as the new window lacks only the pixels
        // that the later commits drew, so it copies only those rects (in the overlap) from the
        // front. Else it copies the overlap, shifted.
        let aged = slots[pick].window == window
        let left = later.map {
            PixelRect(columns: window.pixels.columns.lowerBound..<$0.columns.lowerBound, rows: $0.rows)
        }
        let copies = (aged ? history.filter { $0.commit > slots[pick].commit }.map(\.drawn) : [overlap])
            .map { $0.intersection(left ?? overlap) }.filter { !$0.isEmpty }

        surface.lock(options: [], seed: nil)
        if surface.isInUse { writesInUse += 1 }
        if pick == front { writesOfFront += 1 }
        lastCopied = copies
        if let source, let from {
            source.lock(options: .readOnly, seed: nil)
            // With a shift, the draws after the copies write the strips.
            for rect in copies {
                Self.copy(rect, except: shift == nil ? drawn : .empty, from: source, from, to: surface, window)
            }
            if let shift, let later {
                for band in shift.bands {
                    let rect = PixelRect(columns: later.columns, rows: band.rows.clamped(to: later.rows))
                    Self.copy(rect, by: band.by, from: source, to: surface, window)
                }
            }
            source.unlock(options: .readOnly, seed: nil)
        }
        if let shift, let later {
            // The strips, then the columns of each band of `later` whose source is outside the window.
            let edges = shift.bands.flatMap { band in
                let sourced = (all.lowerBound + band.by)..<(all.upperBound + band.by)
                return [
                    later.columns.lowerBound..<max(later.columns.lowerBound, min(sourced.lowerBound, all.upperBound)),
                    max(
                        later.columns.lowerBound, min(later.columns.upperBound, sourced.upperBound))..<later.columns
                        .upperBound,
                ].map { PixelRect(columns: $0, rows: band.rows.clamped(to: later.rows)) }
            }
            lastDrawn = (strips + edges).filter { !$0.isEmpty }
            for rect in lastDrawn {
                draw(
                    PixelRegion(base: surface.baseAddress, bytesPerRow: surface.bytesPerRow, window: window, rect: rect)
                )
            }
            shifted += 1
        } else {
            lastDrawn = [drawn]
            draw(PixelRegion(base: surface.baseAddress, bytesPerRow: surface.bytesPerRow, window: window, rect: drawn))
        }
        surface.unlock(options: [], seed: nil)

        commits += 1
        history = (history + [(commits, drawn)]).suffix(slots.count - 1)
        slots[pick] = Slot(surface: surface, window: window, commit: commits)
        front = pick
        // A new capacity drops the surfaces of the old one, so each held surface has the capacity of
        // the view. The window server keeps the old front until its next composite.
        for index in slots.indices where slots[index].window?.capacity != window.capacity { slots[index] = Slot() }
        let used = window.pixels
        layer.frame = window.points(of: used)
        layer.contentsScale = window.scale
        layer.contentsRect = CGRect(
            x: 0, y: 0, width: Double(used.columns.count) / Double(window.capacity.columns),
            height: Double(used.rows.count) / Double(window.capacity.rows))
        layer.contents = surface
        return .drawn(drawn)
    }

    /// Test support: the pixel of the layer contents at a document column and row.
    func pixel(column: Int, row: Int) -> UInt32? {
        frontRow(row).flatMap { row in
            guard let window = shown, window.pixels.columns.contains(column) else { return nil }
            return row[column - window.pixels.columns.lowerBound]
        }
    }

    /// Test support: the pixels of the layer contents in a document row, one per column in view.
    func frontRow(_ row: Int) -> [UInt32]? {
        guard let front, let surface = slots[front].surface, let window = slots[front].window,
            window.pixels.rows.contains(row)
        else { return nil }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let start = (surface.baseAddress + (row - window.pixels.rows.lowerBound) * surface.bytesPerRow)
            .assumingMemoryBound(to: UInt32.self)
        return Array(UnsafeBufferPointer(start: start, count: window.pixels.columns.count))
    }

    /// Test support: the surfaces held, with the layer contents.
    var surfaces: [IOSurface] { slots.compactMap(\.surface) }

    /// The bounding rect of the part of `window` outside `overlap`: all of it when the overlap is
    /// empty or leaves pixels on two sides.
    private static func outside(_ overlap: PixelRect, of window: PixelRect) -> PixelRect {
        guard !overlap.isEmpty else { return window }
        func side(_ inner: Range<Int>, _ outer: Range<Int>) -> Range<Int> {
            let (before, after) = (outer.lowerBound..<inner.lowerBound, inner.upperBound..<outer.upperBound)
            if !before.isEmpty, !after.isEmpty { return outer }
            return before.isEmpty ? after : before
        }
        if overlap.rows == window.rows {
            return PixelRect(columns: side(overlap.columns, window.columns), rows: window.rows)
        }
        if overlap.columns == window.columns {
            return PixelRect(columns: window.columns, rows: side(overlap.rows, window.rows))
        }
        return window
    }

    /// Copies the pixels of `overlap` from `source` (which shows `from`) to `target` (which shows
    /// `to`), row by row, except the pixels of `except`, which the draw writes.
    private static func copy(
        _ overlap: PixelRect, except: PixelRect, from source: IOSurface, _ from: LaneWindow, to target: IOSurface,
        _ to: LaneWindow
    ) {
        guard !overlap.isEmpty else { return }
        func address(_ surface: IOSurface, _ window: LaneWindow, _ column: Int, _ row: Int) -> UnsafeMutableRawPointer {
            surface.baseAddress + (row - window.pixels.rows.lowerBound) * surface.bytesPerRow
                + (column - window.pixels.columns.lowerBound) * 4
        }
        let skipped = overlap.columns.clamped(to: except.columns)
        for row in overlap.rows {
            let parts =
                except.rows.contains(row) && !skipped.isEmpty
                ? [overlap.columns.lowerBound..<skipped.lowerBound, skipped.upperBound..<overlap.columns.upperBound]
                : [overlap.columns]
            for part in parts where !part.isEmpty {
                memcpy(
                    address(target, to, part.lowerBound, row), address(source, from, part.lowerBound, row),
                    part.count * 4)
            }
        }
    }

    /// Copies the pixels of `target` from `source`, which shows the same window, moved by `by`
    /// columns: target column c gets source column c - by. A column whose source is outside the
    /// window does not change; the caller draws it.
    private static func copy(
        _ target: PixelRect, by: Int, from source: IOSurface, to surface: IOSurface, _ window: LaneWindow
    ) {
        let all = window.pixels.columns
        let columns = target.columns.clamped(to: (all.lowerBound + by)..<(all.upperBound + by))
        guard !columns.isEmpty else { return }
        for row in target.rows {
            let offset = (row - window.pixels.rows.lowerBound)
            memcpy(
                surface.baseAddress + offset * surface.bytesPerRow + (columns.lowerBound - all.lowerBound) * 4,
                source.baseAddress + offset * source.bytesPerRow + (columns.lowerBound - by - all.lowerBound) * 4,
                columns.count * 4)
        }
    }

    /// A surface of `capacity`, BGRA, tagged sRGB (probe P2: an untagged surface shows other colors).
    /// A row is an odd count of 64-byte lines: the column spans of a lane then use all 64 L1 sets.
    private static func surface(_ capacity: SurfaceCapacity) -> IOSurface? {
        let rowLength = ((capacity.columns + 15) / 16 | 1) * 16
        guard
            let surface = IOSurface(properties: [
                .width: capacity.columns, .height: capacity.rows, .bytesPerElement: 4, .bytesPerRow: rowLength * 4,
                .pixelFormat: kCVPixelFormatType_32BGRA,
            ])
        else { return nil }
        IOSurfaceSetValue(surface, kIOSurfaceColorSpace, srgb)
        return surface
    }

    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!.copyPropertyList()!
}
