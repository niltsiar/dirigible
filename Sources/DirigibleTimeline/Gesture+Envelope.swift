import DirigibleCore
import Foundation

/// The envelope part of the gesture (decision 0060): a drag of a point, an Option press on the gain
/// line that adds a point, a drag of the line inside a range that adds a range gain, and a
/// double-click on a point that removes it. Each makes one Core edit on the session of the
/// mouse-down, as a gain drag does.
extension TimelineGesture {
    /// A drag of one point: `clip` is the clip at the down with the point (an added point is in
    /// it), `index` the point in `clip.envelope.points`, and `added` true for a point that an Option
    /// press made, so the mouse-up commits it with no move.
    struct PointDrag: Sendable {
        let clip: Clip
        let index: Int
        let added: Bool
        var point: GainEnvelope.Point
        var preview: Session
    }

    /// A drag of the gain line inside a range of one clip: the range, the added gain, and the
    /// session with that range gain.
    struct RangeGainDrag: Sendable {
        let clip: Clip
        let lane: Int
        let range: Range<Frames>
        var gain: Gain
        var preview: Session
    }

    /// The gain of the point drag, or of the range gain, as the readout shows it.
    var envelopeReadout: GestureReadout? {
        switch state {
        case .pointing(_, let drag): .point(drag.point.gain)
        case .rangeGaining(_, let drag): .rangeGain(drag.gain)
        default: nil
        }
    }

    /// `session` with `envelope` on `clip`. Nil when the clip does not accept it.
    private static func setting(_ envelope: GainEnvelope?, of clip: Clip, in session: Session) -> Session? {
        var result = session
        guard let envelope, (try? result.setEnvelopes([clip.id: envelope])) != nil else { return nil }
        return result
    }

    /// The clip with a new point at the timeline frame `frame` that changes no sample (the envelope
    /// value there), the index of the point, and the session with it. Nil when a point is there.
    private static func adding(at frame: Frames, to clip: Clip, in session: Session) -> (Clip, Int, Session)? {
        let file = frame - clip.start + clip.offset
        guard let envelope = clip.envelope.withPoint(at: file), let result = setting(envelope, of: clip, in: session),
            let new = result.clip(clip.id)?.clip, let index = envelope.points.firstIndex(where: { $0.frame == file })
        else { return nil }
        return (new, index, result)
    }

    /// The drag state of a press on a point, or of an Option press on the gain line (a new point).
    func pointState(_ press: Press, _ clip: Clip, index: Int?) -> State? {
        if let index {
            return .pointing(
                press,
                PointDrag(
                    clip: clip, index: index, added: false, point: clip.envelope.points[index],
                    preview: press.base))
        }
        guard let (new, index, preview) = Self.adding(at: press.frame, to: clip, in: press.base) else { return nil }
        return .pointing(
            press,
            PointDrag(
                clip: new, index: index, added: true, point: new.envelope.points[index], preview: preview))
    }

    /// The drag state of a press on the gain line: a new point with Option, a range gain inside a
    /// range, else a clip gain drag.
    func gainState(_ press: Press, _ clip: Clip, _ lane: Int) -> State {
        if press.option, let pointing = pointState(press, clip, index: nil) { return pointing }
        if let range = gainRange(press, clip, lane) {
            return .rangeGaining(
                press, RangeGainDrag(clip: clip, lane: lane, range: range, gain: .zero, preview: press.base))
        }
        return .gaining(press, GainDrag(clip: clip, gain: clip.gain, preview: press.base))
    }

    /// A point drag event: the point follows the pointer in time, between its neighbors and inside the
    /// clip window, and in dB (the line stays under the pointer, the waveform range per lane height, rounded to
    /// 0.1 dB, from min(start, `PointGain.floor`) to max(start, `Gain.levelLimit`)). A take ends the drag.
    mutating func pointDrag(_ press: Press, _ drag: PointDrag, _ x: Double, _ y: Double, _ context: GestureContext)
        -> [GestureEffect]
    {
        guard context.canEdit else {
            state = .dropped
            return []
        }
        let points = drag.clip.envelope.points
        let start = points[drag.index]
        let window = drag.clip.offset..<(drag.clip.offset + drag.clip.length)
        let low = max(window.lowerBound, drag.index > 0 ? points[drag.index - 1].frame + Frames(1) : .zero)
        let high = min(
            window.upperBound - Frames(1),
            drag.index + 1 < points.count ? points[drag.index + 1].frame - Frames(1) : .limit)
        let frame = min(max(start.frame + press.delta(to: x, context.geometry), low), high)
        var dB = start.gain.dB
        if y != press.y {
            let geometry = context.geometry
            let moved =
                ((start.gain.dB + geometry.range.decibels(points: press.y - y, laneHeight: geometry.laneHeight)) * 10)
                .rounded() / 10
            dB = min(max(moved, min(start.gain.dB, PointGain.floor)), max(start.gain.dB, Gain.levelLimit))
        }
        guard let gain = Gain(dB: dB), GainEnvelope.Point(frame: frame, gain: gain) != drag.point else { return [] }
        let point = GainEnvelope.Point(frame: frame, gain: gain)
        var moved = points
        moved[drag.index] = point
        // The frame stays between the neighbors, so the order holds. A failure keeps the last preview.
        guard let preview = Self.setting(GainEnvelope(moved), of: drag.clip, in: press.base) else { return [] }
        var drag = drag
        (drag.point, drag.preview) = (point, preview)
        state = .pointing(press, drag)
        return []
    }

    /// The mouse-up of a point drag: one commit when the point moved or was added; else a click.
    func commit(_ press: Press, _ drag: PointDrag, _ context: GestureContext) -> [GestureEffect] {
        guard drag.added || drag.point != drag.clip.envelope.points[drag.index] else { return click(press, context) }
        return [.commit(commit(press, drag.clip, drag.preview))]
    }

    /// The mouse-up of an Option press on the gain line, with no drag: one commit that adds a point
    /// there. Nil (a click) with no Option, off the gain line, with a point at that frame, or during
    /// a take.
    func addPoint(_ press: Press, _ context: GestureContext) -> [GestureEffect]? {
        guard press.option, context.canEdit, case .lane(.gain(let clip, _)) = press.target,
            let (new, _, result) = Self.adding(at: press.frame, to: clip, in: press.base)
        else { return nil }
        return [.commit(commit(press, new, result))]
    }

    /// The mouse-up of a double-click on a point: one commit that removes it. Nil when a take runs.
    func removePoint(_ press: Press, _ clip: Clip, _ index: Int, _ context: GestureContext) -> [GestureEffect]? {
        var points = clip.envelope.points
        points.remove(at: index)
        guard context.canEdit, let result = Self.setting(GainEnvelope(points), of: clip, in: press.base) else {
            return nil
        }
        return [.commit(commit(press, clip, result))]
    }

    /// The range of a range gain: the selected range, when it is inside `clip` and not the whole
    /// clip, `clip`'s track is selected, and the press is inside the range. Else nil: a clip gain drag.
    func gainRange(_ press: Press, _ clip: Clip, _ lane: Int) -> Range<Frames>? {
        guard let selection = press.marks.selection(in: press.base),
            selection.tracks.contains(press.base.tracks[lane].id), selection.range != clip.range,
            selection.range.lowerBound >= clip.start, selection.range.upperBound <= clip.end,
            selection.range.contains(press.frame)
        else { return nil }
        return selection.range
    }

    /// A range-gain drag event: the gain of the range follows the pointer (the waveform range per
    /// lane height, rounded to 0.1 dB, at most `Gain.levelLimit` each way), with ramps of 500 ms. A take ends it.
    mutating func rangeGainDrag(_ press: Press, _ drag: RangeGainDrag, _ y: Double, _ context: GestureContext)
        -> [GestureEffect]
    {
        guard context.canEdit else {
            state = .dropped
            return []
        }
        let geometry = context.geometry
        let dB = (geometry.range.decibels(points: press.y - y, laneHeight: geometry.laneHeight) * 10).rounded() / 10
        guard let gain = Gain(dB: min(max(dB, -Gain.levelLimit), Gain.levelLimit)), gain != drag.gain else { return [] }
        var preview = press.base
        // The range is in the clip, so no input reaches a throw. A throw keeps the last preview.
        guard
            (try? preview.changeGain(
                by: gain, in: drag.range, on: [press.base.tracks[drag.lane].id], ramp: preview.gainRamp))
                != nil
        else { return [] }
        var drag = drag
        (drag.gain, drag.preview) = (gain, preview)
        state = .rangeGaining(press, drag)
        return []
    }

    /// The mouse-up of a range-gain drag: one commit when the gain is not 0, with the range kept as
    /// the selection; else a click.
    func commit(_ press: Press, _ drag: RangeGainDrag, _ context: GestureContext) -> [GestureEffect] {
        guard drag.gain != .zero else { return click(press, context) }
        return [
            .commit(GestureCommit(base: press.base, result: drag.preview, selection: nil, marker: nil, ripple: false))
        ]
    }
}
