import AppKit
import DirigibleCore
import DirigibleTimeline

/// The shift draw of a ripple drag (decision 0037), apart from the lane draw.
extension TimelineDocumentView {
    /// The shift of `shiftedFrames` from `old` to the inputs, when the Marks do not change. The
    /// Marks lines and band stay at their frames, so the copied region starts 1 pt past them in
    /// the old and the new lanes: after a ripple commit, the Marks are on the dragged clip.
    func shift(from old: LaneInputs?) -> ShiftedFrames? {
        guard let old, let inputs, let geometry = inputs.geometry, old.marks == inputs.marks,
            let shift = shiftedFrames(from: old.session, to: inputs.session)
        else { return nil }
        guard let last = [inputs.marks.inPoint, inputs.marks.outPoint].compactMap({ $0 }).max() else { return shift }
        let pad = Frames(Int(geometry.scale.framesPerPoint.rounded(.up)))
        return (max(shift.from, last + pad + max(.zero, shift.delta)), shift.delta, shift.strays)
    }

    /// The pixel form of a shift: the first copied column, 1 pt right of `from` for the rounding of
    /// the renderer; the move in columns; and the strips: from the dirty rect to that column, and
    /// 1 pt around each stray marker line, on every lane in view. Nil when the move is not a whole
    /// number of columns within one frame (a ripple drag moves by whole device columns, and each of the two
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
        let strip = lanes.pixels(
            of: NSRect(x: dirty.minX, y: bounds.minY, width: max(0, x - dirty.minX), height: bounds.height))
        let strays = shift.strays.map {
            lanes.pixels(of: NSRect(x: geometry.x(of: $0) - 1, y: bounds.minY, width: 3, height: bounds.height))
        }
        return LaneSurfaces.Shift(
            column: Int((x * lanes.scale).rounded(.up)), by: Int(columns.rounded()), strips: [strip] + strays)
    }
}
