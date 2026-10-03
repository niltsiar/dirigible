import DirigibleCore
import Foundation

/// What the readout of the window shows during a drag of the gain line or of a fade handle.
public enum GestureReadout: Equatable, Sendable {
    case gain(Gain)
    /// The edge of the fade and its length.
    case fade(Fades.Edge, Frames)
}

/// The clip part of the gesture (run 11b-1): a drag of the gain line sets the clip gain, a drag of
/// a fade handle sets that fade, and a double-click on either resets it. Each makes one Core edit
/// on the session of the mouse-down, as a trim does, and the commit selects the clip.
extension TimelineGesture {
    /// A gain drag: the clip at the down, its lane, the gain, and the session with that gain.
    struct GainDrag: Sendable {
        let clip: Clip
        let lane: Int
        var gain: Gain
        var preview: Session
    }

    /// A fade-handle drag: the clip at the down, the edge, its lane, the fades, and the session
    /// with those fades.
    struct FadeDrag: Sendable {
        let clip: Clip
        let edge: Edge
        let lane: Int
        var fades: Fades
        var preview: Session
    }

    /// The value of a gain or fade drag; nil in every other state.
    public var readout: GestureReadout? {
        switch state {
        case .gaining(_, let drag): .gain(drag.gain)
        case .fading(_, let drag): .fade(drag.edge, drag.edge == .start ? drag.fades.fadeIn : drag.fades.fadeOut)
        default: nil
        }
    }

    /// A gain drag event: the line stays under the pointer (60 dB per lane height), rounded to
    /// 0.1 dB, from min(start, -limit) to max(start, limit) with `Gain.levelLimit`, so a start
    /// outside the limit never jumps. A take ends the drag.
    mutating func gainDrag(_ press: Press, _ drag: GainDrag, _ y: Double, _ context: GestureContext) -> [GestureEffect]
    {
        guard context.canEdit else {
            state = .dropped
            return []
        }
        let start = drag.clip.gain.dB
        let dB = ((start + (press.y - y) * 60 / context.geometry.laneHeight) * 10).rounded() / 10
        guard let gain = Gain(dB: min(max(dB, min(start, -Gain.levelLimit)), max(start, Gain.levelLimit))),
            gain != drag.gain
        else { return [] }
        var preview = press.base
        // The clip is in the base, so no input reaches a throw. A throw keeps the last preview.
        guard (try? preview.setGain(gain, clip: drag.clip.id)) != nil else { return [] }
        var drag = drag
        (drag.gain, drag.preview) = (gain, preview)
        state = .gaining(press, drag)
        return []
    }

    /// A fade-handle drag event: the fade end follows the pointer, from 0 to the start of the other
    /// fade (it never shortens the other fade). A take ends the drag.
    mutating func fadeDrag(_ press: Press, _ drag: FadeDrag, _ x: Double, _ context: GestureContext) -> [GestureEffect]
    {
        guard context.canEdit else {
            state = .dropped
            return []
        }
        let (old, length) = (drag.clip.fades, drag.clip.length)
        let delta = press.delta(to: x, context.geometry)
        let fades =
            drag.edge == .start
            ? Fades(fadeIn: min(max(.zero, old.fadeIn + delta), length - old.fadeOut), fadeOut: old.fadeOut)
            : Fades(fadeIn: old.fadeIn, fadeOut: min(max(.zero, old.fadeOut - delta), length - old.fadeIn))
        guard let fades, fades != drag.fades else { return [] }
        var preview = press.base
        // The clamp keeps the sum in the clip, so no input reaches a throw. A throw keeps the last
        // preview.
        guard (try? preview.setFades([drag.clip.id: fades])) != nil else { return [] }
        var drag = drag
        (drag.fades, drag.preview) = (fades, preview)
        state = .fading(press, drag)
        return []
    }

    /// The mouse-up of a gain drag: one commit when the gain changed; else a click.
    func commit(_ press: Press, _ drag: GainDrag, _ context: GestureContext) -> [GestureEffect] {
        guard drag.gain != drag.clip.gain else { return click(press, context) }
        return [.commit(commit(press, drag.clip, drag.lane, drag.preview))]
    }

    /// The mouse-up of a fade-handle drag: one commit when the fades changed; else a click.
    func commit(_ press: Press, _ drag: FadeDrag, _ context: GestureContext) -> [GestureEffect] {
        guard drag.fades != drag.clip.fades else { return click(press, context) }
        return [.commit(commit(press, drag.clip, drag.lane, drag.preview))]
    }

    /// The mouse-up of a double-click on the gain band or a fade handle: one commit that sets the
    /// gain to 0 dB or that fade to 0. Nil (a click) when it changes nothing or a take runs.
    func reset(_ press: Press, _ context: GestureContext) -> [GestureEffect]? {
        guard press.clicks >= 2, context.canEdit, case .lane(let hit) = press.target else { return nil }
        var result = press.base
        switch hit {
        case .gain(let clip, let lane):
            guard clip.gain != .zero, (try? result.setGain(.zero, clip: clip.id)) != nil else { return nil }
            return [.commit(commit(press, clip, lane, result))]
        case .fade(let clip, let edge, let lane):
            let old = clip.fades
            let fades =
                edge == .start ? Fades(fadeIn: .zero, fadeOut: old.fadeOut) : Fades(fadeIn: old.fadeIn, fadeOut: .zero)
            guard let fades, fades != old, (try? result.setFades([clip.id: fades])) != nil else { return nil }
            return [.commit(commit(press, clip, lane, result))]
        case .move, .trim, .range:
            return nil
        }
    }

    /// The commit of a clip edit, with the Marks on the clip range on its track.
    private func commit(_ press: Press, _ clip: Clip, _ lane: Int, _ result: Session) -> GestureCommit {
        let marks = Marks(inPoint: clip.start, outPoint: clip.end, tracks: [press.base.tracks[lane].id])
        return GestureCommit(base: press.base, result: result, marks: marks, marker: nil)
    }
}
