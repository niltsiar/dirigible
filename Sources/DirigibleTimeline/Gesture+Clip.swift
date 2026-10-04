import DirigibleCore
import Foundation

/// What the readout of the window shows during a drag of the gain line or of a fade handle.
public enum GestureReadout: Equatable, Sendable {
    case gain(Gain)
    /// The edge of the fade and its length.
    case fade(Fades.Edge, Frames)
    /// The length of a crossfade (decision 0036).
    case crossfade(Frames)
}

/// The clip part of the gesture (run 11b-1): a drag of the gain line sets the clip gain, a drag of
/// a fade handle sets that fade or the crossfade of that edge (decision 0036), and a double-click
/// on either resets it. Each makes one Core edit
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

    /// A crossfade-handle drag (decision 0036): the clip at the down, the edge of the handle, its
    /// lane, the left clip of the join, the limit of the join at the down, the length, and the
    /// session with that length.
    struct CrossfadeDrag: Sendable {
        let clip: Clip
        let edge: Edge
        let lane: Int
        let left: ClipID
        let limit: Frames
        var length: Frames
        var preview: Session
    }

    /// The value of a gain, fade, or crossfade drag; nil in every other state.
    public var readout: GestureReadout? {
        switch state {
        case .gaining(_, let drag): .gain(drag.gain)
        case .fading(_, let drag): .fade(drag.edge, drag.edge == .start ? drag.fades.fadeIn : drag.fades.fadeOut)
        case .crossfading(_, let drag): .crossfade(drag.length)
        default: nil
        }
    }

    /// The index of the left clip of the join at `edge` of the clip, in `clips`; nil when the
    /// lane does not hold the clip.
    static func joinLeft(of clip: Clip, _ edge: Edge, in clips: ClipLane) -> Int? {
        clips.index(holding: clip.start).map { edge == .end ? $0 : $0 - 1 }
    }

    /// The drag of a handle: a crossfade drag at an edge with a crossfade, else a fade drag.
    func handleState(_ press: Press, _ clip: Clip, _ edge: Edge, _ lane: Int) -> State {
        let clips = press.base.tracks[lane].clips
        let length = clip.crossfades[edge]
        guard length != .zero, let left = Self.joinLeft(of: clip, edge, in: clips) else {
            return .fading(press, FadeDrag(clip: clip, edge: edge, lane: lane, fades: clip.fades, preview: press.base))
        }
        let limit = press.base.crossfadeLimit(after: left, in: clips) ?? length
        return .crossfading(
            press,
            CrossfadeDrag(
                clip: clip, edge: edge, lane: lane, left: clips[left].id, limit: limit, length: length,
                preview: press.base))
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

    /// A fade-handle drag event: the fade end follows the pointer, from 0 to the room of the edge
    /// (it never shortens the other fade or a crossfade). A take ends the drag.
    mutating func fadeDrag(_ press: Press, _ drag: FadeDrag, _ x: Double, _ context: GestureContext) -> [GestureEffect]
    {
        guard context.canEdit else {
            state = .dropped
            return []
        }
        let old = drag.clip.fades
        let delta = press.delta(to: x, context.geometry)
        let fades = drag.clip.fades(
            setting: drag.edge, to: drag.edge == .start ? old.fadeIn + delta : old.fadeOut - delta)
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

    /// A crossfade-handle drag event, relative to the press: a drag away from the join adds 2 x its
    /// frames, and a drag toward it takes them off, from 0 to the limit at the down. 0 removes the
    /// crossfade from both clips, and a drag back out makes it again. A take ends the drag.
    mutating func crossfadeDrag(_ press: Press, _ drag: CrossfadeDrag, _ x: Double, _ context: GestureContext)
        -> [GestureEffect]
    {
        guard context.canEdit else {
            state = .dropped
            return []
        }
        let twice = Frames(2 * press.delta(to: x, context.geometry).count)
        let start = drag.clip.crossfades[drag.edge]
        let length = min(max(.zero, drag.edge == .end ? start - twice : start + twice), drag.limit)
        guard length != drag.length else { return [] }
        var preview = press.base
        // The clamp keeps the length even and inside the limit, so no input reaches a throw. A
        // throw keeps the last preview.
        guard (try? preview.setCrossfades([drag.left: length])) != nil else { return [] }
        var drag = drag
        (drag.length, drag.preview) = (length, preview)
        state = .crossfading(press, drag)
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

    /// The mouse-up of a crossfade-handle drag: one commit when the length changed; else a click.
    func commit(_ press: Press, _ drag: CrossfadeDrag, _ context: GestureContext) -> [GestureEffect] {
        guard drag.length != drag.clip.crossfades[drag.edge] else { return click(press, context) }
        return [.commit(commit(press, drag.clip, drag.lane, drag.preview))]
    }

    /// The mouse-up of a double-click on the gain band or a handle: one commit that sets the gain
    /// to 0 dB, that fade to 0, or removes the crossfade of that edge. Nil (a click) when it
    /// changes nothing or a take runs.
    func reset(_ press: Press, _ context: GestureContext) -> [GestureEffect]? {
        guard press.clicks >= 2, context.canEdit, case .lane(let hit) = press.target else { return nil }
        var result = press.base
        switch hit {
        case .gain(let clip, let lane):
            guard clip.gain != .zero, (try? result.setGain(.zero, clip: clip.id)) != nil else { return nil }
            return [.commit(commit(press, clip, lane, result))]
        case .fade(let clip, let edge, let lane) where clip.crossfades[edge] != .zero:
            let clips = press.base.tracks[lane].clips
            guard let left = Self.joinLeft(of: clip, edge, in: clips),
                (try? result.setCrossfades([clips[left].id: .zero])) != nil
            else { return nil }
            return [.commit(commit(press, clip, lane, result))]
        case .fade(let clip, let edge, let lane):
            let old = clip.fades
            let fades = clip.fades(setting: edge, to: .zero)
            guard let fades, fades != old, (try? result.setFades([clip.id: fades])) != nil else { return nil }
            return [.commit(commit(press, clip, lane, result))]
        case .move, .trim, .range:
            return nil
        }
    }

    /// The trim of a press on a trim zone: a ripple trim with Option (decision 0037), else the
    /// plain trim. Nil when the file is not in the pool.
    func trim(_ press: Press, _ clip: Clip, _ edge: Edge, _ lane: Int, _ context: GestureContext) -> Trim? {
        guard let file = press.base.files[clip.file] else { return nil }
        let minimum = context.geometry.trimMinimum
        let limits =
            press.option
            ? rippleTrimLimits(clip, edge: edge, fileLength: file.length, minimum: minimum)
            : trimLimits(clip, edge: edge, in: press.base.tracks[lane].clips, fileLength: file.length, minimum: minimum)
        return Trim(
            clip: clip, edge: edge, lane: lane, ripple: press.option, limits: limits, range: clip.range,
            preview: press.base)
    }

    /// A ripple trim drag event: the edge moves by the pointer motion in whole points, clamped to
    /// the limits, and the preview is `rippleTrim` on all tracks. Whole points move the later
    /// region by whole device columns at any zoom, so the lanes can draw it by a shift (decision
    /// 0037). The delta does not stop at x 0, so a start edge at frame 0 extends into its file. The
    /// clip start stays, so the range of a start trim changes at its end.
    mutating func rippleDrag(_ press: Press, _ trim: Trim, _ x: Double, _ geometry: LaneGeometry) -> [GestureEffect] {
        let points = abs(x - press.x) < Self.threshold ? 0 : (x - press.x).rounded()
        let delta = Frames(Int((points * geometry.scale.framesPerPoint).rounded()))
        let moved = min(max(delta, trim.limits.lowerBound), trim.limits.upperBound)
        let range = trim.clip.start..<(trim.edge == .start ? trim.clip.end - moved : trim.clip.end + moved)
        guard range != trim.range else { return [] }
        var preview = press.base
        // The limits keep the clip in its file, so only a later clip past `Frames.limit` throws. A
        // throw keeps the last preview (decision 0020).
        let tracks = press.base.tracks.map(\.id)
        guard (try? preview.rippleTrim(trim.clip.id, edge: trim.edge, by: moved, on: tracks)) != nil else { return [] }
        var trim = trim
        (trim.range, trim.preview) = (range, preview)
        state = .trimming(press, trim)
        return []
    }

    /// The Marks after a right-click at `place` (decision 0037, `ui-panel.md` 5): the range of the
    /// clip under it on its track, as a click gives, when the click is outside the selection. Nil
    /// inside the selection, in a gap, and outside the lanes: the Marks stay.
    public static func contextMarks(at place: Place, _ context: GestureContext) -> Marks? {
        guard case .lanes(let x, let y) = place else { return nil }
        let session = context.session
        switch context.geometry.hit(x, y, in: session) {
        case .move(let clip, let lane), .trim(let clip, _, let lane), .gain(let clip, let lane),
            .fade(let clip, _, let lane):
            let track = session.tracks[lane].id
            if let selection = context.marks.selection(in: session), selection.tracks.contains(track),
                selection.range.contains(context.geometry.frame(at: x))
            {
                return nil
            }
            return Marks(inPoint: clip.start, outPoint: clip.end, tracks: [track])
        case .range: return nil
        }
    }

    /// The commit of a clip edit, with the Marks on the clip range on its track.
    private func commit(_ press: Press, _ clip: Clip, _ lane: Int, _ result: Session) -> GestureCommit {
        let marks = Marks(inPoint: clip.start, outPoint: clip.end, tracks: [press.base.tracks[lane].id])
        return GestureCommit(base: press.base, result: result, marks: marks, marker: nil)
    }
}
