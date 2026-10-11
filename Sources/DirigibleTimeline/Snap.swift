import DirigibleCore
import Foundation

/// The snap targets of one drag (decision 0020): the clip edges of every lane except the clips of
/// `excluded`, the markers and chapters, and the playhead of each event. A clip narrower than
/// `LaneGeometry.grabWidth` on screen gives no target, so a drag at fit zoom does not stop at each
/// clip that the user cannot see. The in and out points are never targets.
struct Snap: Sendable {
    /// The reach of a snap (points) at every zoom: a calibration knob of the snap run UI panel.
    static let distance = 6.0

    let lanes: [ClipLane]
    let excluded: Set<ClipID>
    /// The marker and chapter positions, sorted once at the drag start.
    let markers: [Frames]
    let geometry: LaneGeometry

    init(_ session: Session, excluding excluded: Set<ClipID> = [], geometry: LaneGeometry) {
        lanes = session.tracks.map(\.clips)
        self.excluded = excluded
        markers = session.markers.values.map(\.position).sorted()
        self.geometry = geometry
    }

    /// The shift that puts the nearest of `edges` on the nearest target in reach, and that target.
    /// Nil when no target is in reach. At an equal distance the playhead wins, then a marker, then
    /// a clip edge.
    func shift(_ edges: [Frames], playhead: Frames) -> (by: Frames, target: Frames)? {
        let reach = Int(Self.distance * geometry.scale.framesPerPoint)
        // The order key: the distance in frames, then the rank of the target kind.
        var best: (distance: Int, rank: Int, edge: Frames, target: Frames)?
        func offer(_ edge: Frames, _ target: Frames, rank: Int) {
            let distance = abs((target - edge).count)
            guard distance <= reach else { return }
            if let best, (best.distance, best.rank) <= (distance, rank) { return }
            best = (distance, rank, edge, target)
        }
        for edge in edges {
            offer(edge, playhead, rank: 0)
            for marker in nearestMarkers(to: edge) { offer(edge, marker, rank: 1) }
            for clips in lanes { clipEdges(near: edge, reach: reach, in: clips) { offer(edge, $0, rank: 2) } }
        }
        return best.map { ($0.target - $0.edge, $0.target) }
    }

    /// The markers just before and at or after `frame`: the nearest is one of them.
    private func nearestMarkers(to frame: Frames) -> ArraySlice<Frames> {
        let index = Self.firstIndex(in: markers.count) { markers[$0] >= frame }
        return markers[max(0, index - 1)..<min(markers.count, index + 1)]
    }

    /// Calls `body` with each edge in reach of `frame` of a clip that is not excluded and is at
    /// least `LaneGeometry.grabWidth` wide. The clips do not overlap, so their starts and their ends
    /// are both sorted: the walk starts at the first clip that starts at or after `frame` and goes
    /// out on both sides until a clip is out of reach.
    private func clipEdges(near frame: Frames, reach: Int, in clips: ClipLane, _ body: (Frames) -> Void) {
        let narrowest = LaneGeometry.grabWidth * geometry.scale.framesPerPoint
        func visit(_ clip: Clip) {
            guard Double(clip.length.count) >= narrowest, !excluded.contains(clip.id) else { return }
            if abs((clip.start - frame).count) <= reach { body(clip.start) }
            if abs((clip.end - frame).count) <= reach { body(clip.end) }
        }
        let first = Self.firstIndex(in: clips.count) { clips[$0].start >= frame }
        var right = first
        while right < clips.count {
            let clip = clips[right]
            if (clip.start - frame).count > reach { break }
            visit(clip)
            right += 1
        }
        var left = first - 1
        while left >= 0 {
            let clip = clips[left]
            if (frame - clip.end).count > reach { break }
            visit(clip)
            left -= 1
        }
    }

    /// The first index in `0..<count` where `isAfter` is true (a binary search; `isAfter` is false
    /// then true along the indices), or `count`.
    private static func firstIndex(in count: Int, where isAfter: (Int) -> Bool) -> Int {
        var (low, high) = (0, count)
        while low < high {
            let middle = (low + high) / 2
            if isAfter(middle) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}

extension Snap {
    /// The snap step of a drag (decision 0020): the delta after the nearest of `edges` moved by
    /// `delta` goes on a target in reach, and that target. No snap targets, snap off, or a delta of
    /// zero (under the 3 pt threshold, so a click never snaps) keep the delta, with no target.
    static func snapped(_ snap: Snap?, _ delta: Frames, _ edges: [Frames], _ context: GestureContext)
        -> (delta: Frames, target: Frames?)
    {
        guard let snap, context.snaps, delta != .zero,
            let shifted = snap.shift(edges.map { $0 + delta }, playhead: context.playhead)
        else { return (delta, nil) }
        return (delta + shifted.by, shifted.target)
    }

    /// The guide: `target` when an edge after the clamps is on it, else nil.
    static func guide(_ target: Frames?, on edges: [Frames]) -> Frames? {
        target.flatMap { edges.contains($0) ? $0 : nil }
    }
}

extension TimelineGesture {
    /// The frame of the target that an edge of the drag is on, for the guide line; else nil.
    public var guide: Frames? {
        switch state {
        case .moving(_, let move): move.guide
        case .grouping(_, let group): group.guide
        case .trimming(_, let trim): trim.guide
        case .ranging(_, _, let guide): guide
        default: nil
        }
    }

    /// A range drag with the snap targets of the session at the down.
    func rangeState(_ press: Press, _ context: GestureContext) -> State {
        .ranging(press, Snap(press.base, geometry: context.geometry), guide: nil)
    }

    /// A range drag event. The pointer end snaps after 3 pt of horizontal movement from the press,
    /// so a vertical drag across the lanes keeps its frames (snap run plan gate 1); the press end
    /// never snaps.
    mutating func rangeDrag(_ press: Press, _ snap: Snap, _ x: Double, _ y: Double, _ context: GestureContext)
        -> [GestureEffect]
    {
        let geometry = context.geometry
        var end = geometry.frame(at: x)
        var guide: Frames?
        if context.snaps, abs(x - press.x) >= Self.threshold,
            let shifted = snap.shift([end], playhead: context.playhead)
        {
            (end, guide) = (shifted.target, shifted.target)
        }
        state = .ranging(press, snap, guide: guide)
        let drag = Marks.drag(
            from: press.frame, to: end, lanes: (geometry.lane(at: press.y), geometry.lane(at: y)), in: context.session)
        return [.selection(.range(press.shift ? press.marks.extended(by: drag) : drag))]
    }
}
