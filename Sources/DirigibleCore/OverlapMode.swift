import Foundation

/// What a move does to the clips under the moved clip (decision 0020). Shuffle is no mode: it is a
/// ripple, so it has its own method (`Session.shuffle`).
public enum OverlapMode: String, CaseIterable, Sendable {
    /// The moved clip overwrites the clips under it (decision 0003).
    case overwrite
    /// A move that would cover a clip throws `.overlap`.
    case noOverlap
    /// The move overwrites, then each join with a clip that it covered gets a crossfade of the
    /// covered length, rounded down to even and held by `crossfadeLimit(after:in:)` (decision 0036).
    case crossfade
}

extension Session {
    /// The starts of the clip on `track` where it covers no other clip of the lane, as the span that
    /// holds `start`. For a covered `start` it is the nearest span, and a tie goes to the earlier one.
    /// Each end of the span passes `move(_:to:start:mode: .noOverlap)`, and one frame past an end
    /// covers a clip or passes `Frames.limit`. The last span ends at `Frames.limit`. A lane with no
    /// room for the clip, up to `Frames.limit`, throws `.frameOutOfRange`.
    public func freeSpan(of id: ClipID, on track: TrackID, near start: Frames) throws(SessionError)
        -> ClosedRange<Frames>
    {
        let (clipTrack, clipIndex) = try position(of: id)
        let clip = tracks[clipTrack].clips[clipIndex]
        let lane = tracks[try trackIndex(track)]
        guard let file = files[clip.file], file.layout == lane.layout else {
            throw .layoutMismatch(lane.id, .file(clip.file))
        }
        var spans: [ClosedRange<Frames>] = []
        var free = Frames.zero
        for other in lane.clips where other.id != id {
            if other.start - clip.length >= free { spans.append(free...(other.start - clip.length)) }
            free = Swift.max(free, other.end)
        }
        if free <= Frames.limit { spans.append(free...Frames.limit) }
        func distance(_ span: ClosedRange<Frames>) -> Frames {
            start < span.lowerBound
                ? span.lowerBound - start : (start > span.upperBound ? start - span.upperBound : .zero)
        }
        guard let nearest = spans.min(by: { distance($0) < distance($1) }) else { throw .frameOutOfRange }
        return nearest
    }

    /// For each clip of `moved`, the frames of `lane` that its head and its tail cover where a clip
    /// of the lane continues past them: those are the joins that Crossfade mode crossfades. `lane`
    /// is the lane before the drop, with the moved clips out.
    func dropCovers(_ moved: [Clip], in lane: ClipLane) -> [ClipID: (head: Frames, tail: Frames)] {
        var covers: [ClipID: (head: Frames, tail: Frames)] = [:]
        for clip in moved {
            let head = lane.index(cutting: clip.start).map { Swift.min(lane[$0].end, clip.end) - clip.start }
            let tail = lane.index(cutting: clip.end).map { clip.end - Swift.max(lane[$0].start, clip.start) }
            if head != nil || tail != nil { covers[clip.id] = (head ?? .zero, tail ?? .zero) }
        }
        return covers
    }

    /// Crossfades the joins that the drop of `covers` made on the lane at `index`. A neighbor that
    /// moved too makes no join of its own. Each length is the covered length rounded down to even,
    /// held by `crossfadeLimit(after:in:)`; a length of 0 makes no crossfade.
    mutating func crossfadeDrops(
        _ covers: [ClipID: (head: Frames, tail: Frames)], on index: Int, moving: Set<ClipID>
    ) throws(SessionError) {
        let lane = tracks[index].clips
        var joins: [(index: Int, length: Frames)] = []
        func add(_ left: Int, covered: Frames) {
            guard lane.join(after: left) != .none, let limit = crossfadeLimit(after: left, in: lane) else { return }
            let length = Swift.min(covered - Frames(covered.count % 2), limit)
            if length > .zero { joins.append((left, length)) }
        }
        for position in lane.indices {
            guard let cover = covers[lane[position].id] else { continue }
            if position > lane.startIndex, !moving.contains(lane[position - 1].id) {
                add(position - 1, covered: cover.head)
            }
            if position + 1 < lane.endIndex, !moving.contains(lane[position + 1].id) {
                add(position, covered: cover.tail)
            }
        }
        if !joins.isEmpty { try setCrossfades(lanes: [index: joins]) }
    }
}
