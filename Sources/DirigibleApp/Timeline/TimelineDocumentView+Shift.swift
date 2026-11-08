import AppKit
import DirigibleCore
import DirigibleTimeline

/// The shift draw of a ripple drag (decision 0037), apart from the lane draw.
extension TimelineDocumentView {
    /// The shift of `shiftedFrames` from `old` to the inputs, when the Marks do not change. The
    /// Marks lines and band stay at their frames, so the copied region starts 1 pt past them in
    /// the old and the new lanes. A clip set has no Marks, so it needs no such start.
    func shift(from old: LaneInputs?) -> ShiftedFrames? {
        guard let old, let inputs, let geometry = inputs.geometry, old.selection == inputs.selection,
            let shift = shiftedFrames(from: old.session, to: inputs.session)
        else { return nil }
        guard let last = [inputs.marks.inPoint, inputs.marks.outPoint].compactMap({ $0 }).max() else { return shift }
        let pad = Frames(Int(geometry.scale.framesPerPoint.rounded(.up)))
        return (
            max(shift.from, last + pad + max(.zero, shift.delta)), shift.delta, shift.strays, shift.still, shift.lines
        )
    }

    /// The pixel form of a shift: the first copied column, 1 pt right of `from` for the rounding of
    /// the renderer; one band for each run of lanes in view that move, or that are still; and the
    /// strips. A band of lanes that move moves by the shift in columns and draws from the dirty rect
    /// to that column and 1 pt around each stray marker line. A band of still lanes keeps its pixels
    /// and draws only the column of each line of `lines`. Nil when the move is not a whole number of
    /// columns within one frame (a ripple drag moves by whole device columns, and each of the two
    /// previews rounds its frames at a zoom that is not whole), or not exact outside a gesture.
    func laneShift(
        _ shift: ShiftedFrames, _ dirty: NSRect, _ lanes: LaneWindow
    ) -> LaneSurfaces.Shift? {
        guard let geometry = inputs?.geometry, !dirty.isNull else { return nil }
        let framesPerColumn = geometry.scale.framesPerPoint / lanes.scale
        let columns = Double(shift.delta.count) / framesPerColumn
        // A rounded move only in a gesture: its end draws the lanes in full. An edit, an undo, or a
        // redo has no such end, so it takes an exact move only.
        let rounded = columns != columns.rounded()
        guard abs(columns - columns.rounded()) * framesPerColumn <= 1, abs(columns) < 1e9, !rounded || holdsWidth
        else { return nil }
        if rounded { roundedShift = true }
        let x = geometry.x(of: shift.from) + 1
        func span(_ minX: Double, _ maxX: Double) -> Range<Int> {
            lanes.pixels(of: NSRect(x: minX, y: bounds.minY, width: max(0, maxX - minX), height: bounds.height)).columns
        }
        let moving = [span(dirty.minX, x)] + shift.strays.map { span(geometry.x(of: $0) - 1, geometry.x(of: $0) + 2) }
        let still = shift.lines.map {
            let column = LaneRenderer.lineColumn($0, geometry, scale: lanes.scale)
            return column..<column + 1
        }
        var runs: [(lanes: Range<Int>, still: Bool)] = []
        for lane in lanes.lanes(of: lanes.pixels.rows) {
            let isStill = shift.still.contains(lane)
            if let last = runs.last, last.still == isStill {
                runs[runs.count - 1].lanes = last.lanes.lowerBound..<lane + 1
            } else {
                runs.append((lane..<lane + 1, isStill))
            }
        }
        let by = Int(columns.rounded())
        var bands: [LaneSurfaces.Shift.Band] = []
        var strips: [PixelRect] = []
        for run in runs {
            let rows = lanes.rows(of: run.lanes).clamped(to: lanes.pixels.rows)
            bands.append(LaneSurfaces.Shift.Band(rows: rows, by: run.still ? 0 : by))
            strips += (run.still ? still : moving).filter { !$0.isEmpty }.map { PixelRect(columns: $0, rows: rows) }
        }
        return LaneSurfaces.Shift(column: Int((x * lanes.scale).rounded(.up)), bands: bands, strips: strips)
    }
}
