import DirigibleAudio
import DirigibleCore
import Foundation

/// The zoom of a timeline (decision 0017). Window state, never saved.
struct TimelineScale: Hashable {
    var framesPerPoint: Double

    /// From the closest zoom, max(128, end / 2^23) frames per point (one 256-frame bin per 2 px
    /// at 2x; probe D6 drew 10.8 million points), to the fit of max(end, 10 s) + 2% over `width`.
    static func limits(end: Frames, rate: Int, width: Double) -> ClosedRange<Double> {
        let closest = max(128, Double(end.count) / 8_388_608)
        let fit = Double(max(end.count, 10 * rate)) * 1.02 / max(1, width)
        return closest...max(closest, fit)
    }

    /// The scale times `factor`, clamped to `limits`, and the origin (the frame at the left edge)
    /// that keeps `anchor` at `x` points from the left edge. The origin is never before 0.
    func zoomed(by factor: Double, anchor: Frames, at x: Double, limits: ClosedRange<Double>)
        -> (scale: TimelineScale, origin: Double)
    {
        let points = (framesPerPoint * factor).clamped(to: limits)
        return (TimelineScale(framesPerPoint: points), max(0, Double(anchor.count) - x * points))
    }

    /// Zoom to Session: 0 to the end + 2% (origin 0).
    static func fit(end: Frames, width: Double, limits: ClosedRange<Double>) -> TimelineScale {
        TimelineScale(framesPerPoint: (Double(end.count) * 1.02 / max(1, width)).clamped(to: limits))
    }

    /// Zoom to Selection: the range with 5% of its length on each side.
    static func fit(_ range: Range<Frames>, width: Double, limits: ClosedRange<Double>)
        -> (scale: TimelineScale, origin: Double)
    {
        let length = Double((range.upperBound - range.lowerBound).count)
        let margin = length * 0.05
        let points = ((length + 2 * margin) / max(1, width)).clamped(to: limits)
        return (TimelineScale(framesPerPoint: points), max(0, Double(range.lowerBound.count) - margin))
    }
}

extension Double {
    fileprivate func clamped(to limits: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, limits.lowerBound), limits.upperBound)
    }
}

/// The anchor of the zoom keys: the playhead when it is in the view, else the view center.
/// `origin` is the frame at the left edge; `width` is in points.
func zoomAnchor(playhead: Frames, origin: Double, width: Double, scale: TimelineScale) -> (frame: Frames, x: Double) {
    let x = (Double(playhead.count) - origin) / scale.framesPerPoint
    if x >= 0, x < width { return (playhead, x) }
    return (Frames(Int(origin + width / 2 * scale.framesPerPoint)), width / 2)
}

/// The page turn of Automatic Scroll: the new origin, or nil for no turn. Forward play turns when
/// the playhead is past 94% of the `frames` in view, or before the view, and shows it at 11%.
/// Reverse play mirrors it: under 6% or after the view, to 89%. The origin is never before 0.
func followOrigin(playhead: Frames, origin: Double, frames: Double, direction: Shuttle.Direction) -> Double? {
    let at = (Double(playhead.count) - origin) / frames
    let (turn, to) = direction == .forward ? (at < 0 || at > 0.94, 0.11) : (at < 0.06 || at > 1, 0.89)
    return turn ? max(0, (Double(playhead.count) - to * frames).rounded()) : nil
}

/// The playhead line between two polls: the polled frame plus the time since the poll, at most
/// 50 ms (a calibration knob), times the rate and the direction of the shuttle.
func playheadFrame(
    polled: Frames, at poll: ContinuousClock.Instant, now: ContinuousClock.Instant, playback: Playback, rate: Int
) -> Double {
    guard case .playing(let shuttle) = playback else { return Double(polled.count) }
    let seconds = min(max(0, (now - poll) / .seconds(1)), 0.05)
    let sign: Double = shuttle.direction == .forward ? 1 : -1
    return max(0, Double(polled.count) + sign * seconds * shuttle.rate.rawValue * Double(rate))
}

/// The frames and the lanes that a window shows fully.
struct TimelineVisible: Hashable {
    var frames: Range<Frames>
    var lanes: Range<Int>
}

/// The narrowed record-over warning (decisions 0016, 0017): true when an armed track has a clip
/// at the playhead and its lane is not fully in view or the playhead is outside the visible
/// frames. Before the first layout (`visible` nil) nothing is in view.
func recordOverHidden(session: Session, armed: Set<TrackID>, playhead: Frames, visible: TimelineVisible?) -> Bool {
    session.tracks.enumerated().contains { lane, track in
        guard armed.contains(track.id), session.hasClip(at: playhead, on: [track.id]) else { return false }
        guard let visible else { return true }
        return !visible.lanes.contains(lane) || !visible.frames.contains(playhead)
    }
}

/// The timeline state of one window (decision 0017). None of it is saved.
struct TimelineState {
    var marks = Marks()
    var scale = TimelineScale(framesPerPoint: 512)
    /// Automatic Scroll: on at open.
    var follows = true
    /// A user scroll during play: no page turn until the playhead is in view again, a seek, or a
    /// play start.
    var followHeld = false
    /// Nil before the first layout.
    var visible: TimelineVisible?

    /// A display tick or a seek during play: the new origin, or nil.
    mutating func follow(playhead: Frames, origin: Double, frames: Double, direction: Shuttle.Direction) -> Double? {
        if followHeld {
            let at = Double(playhead.count) - origin
            guard at >= 0, at < frames else { return nil }
            followHeld = false
        }
        guard follows else { return nil }
        return followOrigin(playhead: playhead, origin: origin, frames: frames, direction: direction)
    }
}

/// The in point, the out point, and the selected tracks of a window (decision 0017). Window
/// state in `SessionWindow`, never in `Session`.
struct Marks: Hashable {
    var inPoint: Frames?
    var outPoint: Frames?
    var tracks: Set<TrackID> = []

    /// The one read of the selection: nil unless in < out and at least one selected track exists
    /// in `session`. The tracks are in session order, so a track that an undo removed drops out.
    func selection(in session: Session) -> (range: Range<Frames>, tracks: [TrackID])? {
        guard let inPoint, let outPoint, inPoint < outPoint else { return nil }
        let kept = session.tracks.map(\.id).filter(tracks.contains)
        return kept.isEmpty ? nil : (inPoint..<outPoint, kept)
    }

    /// A drag from the frame `from` to `to` over the lanes `lanes.0` through `lanes.1`, in any
    /// order. A lane past the last one counts as the last one.
    static func drag(from: Frames, to: Frames, lanes: (Int, Int), in session: Session) -> Marks {
        let last = session.tracks.count - 1
        let low = max(0, min(lanes.0, lanes.1, last))
        let high = min(max(lanes.0, lanes.1), last)
        guard low <= high else { return Marks() }
        return Marks(
            inPoint: min(from, to), outPoint: max(from, to), tracks: Set(session.tracks[low...high].map(\.id)))
    }

    /// Shift-click: the range from the playhead to the click, and the lane joins the tracks.
    func extended(to frame: Frames, lane: TrackID, playhead: Frames) -> Marks {
        Marks(inPoint: min(frame, playhead), outPoint: max(frame, playhead), tracks: tracks.union([lane]))
    }

    /// Command-click: the lane goes into or out of the tracks. With no tracks left, no Marks.
    func toggled(_ track: TrackID) -> Marks {
        var marks = self
        if marks.tracks.remove(track) == nil { marks.tracks.insert(track) }
        return marks.tracks.isEmpty ? Marks() : marks
    }

    /// I: in at the playhead; an out at or before it goes. With no tracks, all tracks.
    func settingIn(_ playhead: Frames, in session: Session) -> Marks {
        var marks = withTracks(of: session)
        marks.inPoint = playhead
        if let out = outPoint, out <= playhead { marks.outPoint = nil }
        return marks
    }

    /// O: out at the playhead; an in at or after it goes. With no tracks, all tracks.
    func settingOut(_ playhead: Frames, in session: Session) -> Marks {
        var marks = withTracks(of: session)
        marks.outPoint = playhead
        if let point = inPoint, point >= playhead { marks.inPoint = nil }
        return marks
    }

    private func withTracks(of session: Session) -> Marks {
        var marks = self
        if marks.tracks.isEmpty { marks.tracks = Set(session.tracks.map(\.id)) }
        return marks
    }

    /// The tracks of a paste (decision 0018): the first selected track in session order and the
    /// tracks under it, one per lane of `excerpt`; with no selected track, the source tracks. Nil
    /// when the tracks under it are too few or a source track is gone.
    func pasteTracks(for excerpt: Excerpt, in session: Session) -> [TrackID]? {
        let ids = session.tracks.map(\.id)
        guard let first = ids.firstIndex(where: tracks.contains) else {
            let sources = excerpt.lanes.map(\.source)
            return sources.allSatisfy(ids.contains) ? sources : nil
        }
        let targets = ids[first...].prefix(excerpt.lanes.count)
        return targets.count == excerpt.lanes.count ? Array(targets) : nil
    }

    /// Select All: 0 to the end on every track. An empty session gives no Marks.
    static func all(in session: Session) -> Marks {
        session.end == .zero
            ? Marks() : Marks(inPoint: .zero, outPoint: session.end, tracks: Set(session.tracks.map(\.id)))
    }
}
