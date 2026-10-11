import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation

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

/// The record-over overlay (decisions 0016, 0017). A take replaces the armed tracks from the
/// playhead on, and its length is not known at the start. Thus the overlay reads only the first
/// clip of each armed track that ends after the playhead: the clip that Record reaches first. True
/// when that clip is not in view: its lane is not fully in view, or its first frame that Record
/// reaches is outside the visible frames. Before the first layout (`visible` nil) nothing is in view.
func recordOverHidden(session: Session, armed: Set<TrackID>, playhead: Frames, visible: TimelineVisible?) -> Bool {
    session.tracks.enumerated().contains { lane, track in
        guard armed.contains(track.id), let clip = track.clips.first(where: { $0.end > playhead }) else { return false }
        guard let visible else { return true }
        return !visible.lanes.contains(lane) || !visible.frames.contains(max(playhead, clip.start))
    }
}

/// The timeline state of one window (decision 0017). None of it is saved.
struct TimelineState {
    var selection = Selection.none
    var scale = TimelineScale(framesPerPoint: 512)
    /// Automatic Scroll: on at open.
    var follows = true
    /// A user scroll that moves the view horizontally during play or a take: no page turn until
    /// the head is in view again, a seek, a play start, or a take start. "Again" is after the head
    /// left the view: a scroll that starts with the head in view keeps the hold (Phase 7 finding
    /// V3).
    var followHeld = false {
        didSet { if !followHeld { headLeftView = false } }
    }
    /// The head was out of the view at a tick of the hold.
    var headLeftView = false
    /// Nil before the first layout.
    var visible: TimelineVisible?
    /// Taller Tracks and Shorter Tracks: automatic at open (0025).
    var laneHeight = LaneHeight.automatic
    /// The zoom history has a step back or forward: Zoom Back and Zoom Forward are on (U5).
    var canGoBack = false
    var canGoForward = false
    /// The current marker (decision 0018): Marker Info…, Move, and Delete act on it. An undo can
    /// remove it from the session; then they beep.
    var marker: MarkerID?

    /// A display tick during play or a take, or a seek: the new origin, or nil.
    mutating func follow(playhead: Frames, origin: Double, frames: Double, direction: Shuttle.Direction) -> Double? {
        if followHeld {
            let at = Double(playhead.count) - origin
            guard at >= 0, at < frames else {
                headLeftView = true
                return nil
            }
            guard headLeftView else { return nil }
            followHeld = false
        }
        guard follows else { return nil }
        return followOrigin(playhead: playhead, origin: origin, frames: frames, direction: direction)
    }
}

extension NSCursor {
    /// The cursor of a timeline cursor kind (probe C1: each exists at the macOS 14 target).
    static func timeline(_ kind: TimelineCursor) -> NSCursor {
        switch kind {
        case .arrow: .arrow
        case .iBeam: .iBeam
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .resizeLeftRight: .resizeLeftRight
        case .resizeUpDown: .resizeUpDown
        case .rippleTrim(.start): .resizeLeft
        case .rippleTrim(.end): .resizeRight
        }
    }
}

extension NSRect {
    init(_ rect: Rect) { self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}
