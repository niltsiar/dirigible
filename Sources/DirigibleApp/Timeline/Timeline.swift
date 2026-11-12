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

/// The frames and the lanes that a window shows (`LaneGeometry.lanesInView`).
struct TimelineVisible: Hashable {
    var frames: Range<Frames>
    var lanes: Range<Int>
}

/// The record-over warning (decisions 0016, 0017): in lane order, each armed track whose first
/// reached clip is not in view, with that clip. Empty for no warning. It holds no playhead time, so
/// a play changes it only when the first reached clip of a track changes.
struct RecordOverWarning: Equatable {
    struct Reached: Equatable {
        let track: TrackID
        let clip: ClipID
        let name: String
    }
    var reached: [Reached] = []
    /// The earliest start of the reached clips, and the sample rate that its text needs. Nil for
    /// an empty warning.
    var start: Frames?
    var rate = 48_000

    var isEmpty: Bool { reached.isEmpty }

    /// `record.over.detail` with the names of the tracks and the earliest clip start. The consent
    /// sheet has its own text: its time is the take start.
    var detail: String {
        guard let start else { return "" }
        return L10n.recordOverDetail.format(
            ListFormatter.localizedString(byJoining: reached.map(\.name)),
            timeDisplayText(start, rate: rate, playing: false))
    }
}

/// The record-over warning (decisions 0016, 0017). A take replaces the armed tracks from the
/// playhead on, and its length is not known at the start. Thus the warning reads only the first
/// clip of each armed track that ends after the playhead: the clip that Record reaches first. That
/// clip is hidden when its lane is not in view, or its first frame that Record reaches is outside
/// the visible frames. Before the first layout (`visible` nil) nothing is in view.
func recordOverHidden(session: Session, armed: Set<TrackID>, playhead: Frames, visible: TimelineVisible?)
    -> RecordOverWarning
{
    var warning = RecordOverWarning()
    for (lane, track) in session.tracks.enumerated() where armed.contains(track.id) {
        guard let clip = track.clips.first(where: { $0.end > playhead }) else { continue }
        if let visible, visible.lanes.contains(lane), visible.frames.contains(max(playhead, clip.start)) { continue }
        warning.reached.append(.init(track: track.id, clip: clip.id, name: track.name))
        warning.start = min(warning.start ?? clip.start, clip.start)
        warning.rate = session.sampleRate
    }
    return warning
}

/// The timeline state of one window (decision 0017). None of it is saved.
struct TimelineState {
    var selection = Selection.none {
        didSet { laneRows(from: oldValue) }
    }
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
    var marker: MarkerID? {
        didSet { selectRows(marker.map { [.marker($0)] } ?? [], anchor: marker.map { .marker($0) }, form: .lane) }
    }
    /// The rows of the index list that are selected, and the row that a range starts from. Only
    /// `selectRows` and `pruneRows(keeping:)` write them.
    private(set) var selectedRows: Set<SessionIndex.Pick> = []
    private(set) var anchorRow: SessionIndex.Pick?
    /// Raised at each write of the rows: the window gives the list the rows when it changes.
    private(set) var rowsRevision = 0

    /// Who writes the rows. A row action of the list (`index`) writes the selection and the current
    /// marker first, then the rows. A write of the lanes (`lane`) comes from the `didSet` of
    /// `selection` or `marker`, writes only the rows, and so calls nothing again.
    enum RowForm { case index, lane }

    mutating func selectRows(_ rows: Set<SessionIndex.Pick>, anchor: SessionIndex.Pick?, form: RowForm = .index) {
        if form == .index {
            let clips = Set(rows.compactMap { if case .clip(let id) = $0 { id } else { nil } })
            if let set = ClipSet(clips) { selection = .clips(set) }
            if case .marker(let id)? = anchor { marker = id }
        }
        selectedRows = rows
        anchorRow = anchor
        rowsRevision += 1
    }

    /// Drops each selected row whose item is not in `live`, and moves a gone anchor to the first
    /// row of `order` that stays (any row that stays without an order). Writes no other field.
    mutating func pruneRows(
        keeping live: Set<SessionIndex.Pick>, order: @autoclosure () -> [SessionIndex.Pick] = []
    ) {
        let kept = selectedRows.intersection(live)
        guard kept != selectedRows else { return }
        selectedRows = kept
        if let anchor = anchorRow, !kept.contains(anchor) {
            anchorRow = order().first(where: kept.contains) ?? kept.first
        }
        rowsRevision += 1
    }

    /// The lane form of `selectRows` after a write of `selection`: one row for each clip of a clip
    /// set, none for a range. The anchor is the one clip that the write adds, else the old anchor
    /// while it stays selected, else nil (`ClipSet` holds no clicked clip).
    private mutating func laneRows(from old: Selection) {
        var rows: Set<SessionIndex.Pick> = []
        var anchor: SessionIndex.Pick?
        if case .clips(let set) = selection {
            rows = Set(set.ids.map { .clip($0) })
            var added = set.ids
            if case .clips(let before) = old { added.subtract(before.ids) }
            if added.count == 1, let id = added.first {
                anchor = .clip(id)
            } else {
                anchor = anchorRow.flatMap { rows.contains($0) ? $0 : nil }
            }
        }
        selectRows(rows, anchor: anchor, form: .lane)
    }

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
