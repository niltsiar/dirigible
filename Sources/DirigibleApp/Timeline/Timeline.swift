import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation

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

/// The marker of the rename alert and the name that the user types.
struct MarkerRename: Hashable {
    let id: MarkerID
    var name: String
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
    /// The current marker (decision 0018): Rename, Move, and Delete act on it. An undo can remove
    /// it from the session; then they do nothing.
    var marker: MarkerID?
    /// The rename alert: open while not nil.
    var renaming: MarkerRename?

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
