import Foundation

/// Roll and slip (decision 0036). `rollLimits` and `slipLimits` are the one statement of the limit
/// rule: the edits throw the reason of `check` past an end, and tests keep the two in step.
extension Session {
    /// The deltas that `roll(_:by:)` accepts for the join after `left`, with the least clip length
    /// that `check` keeps: one frame, or both crossfade halves. Nil when `left` is unknown or no clip
    /// touches its end.
    public func rollLimits(_ left: ClipID) -> ClosedRange<Frames>? {
        guard let (track, index) = try? position(of: left), tracks[track].clips.join(after: index) != .none else {
            return nil
        }
        let (a, b) = (tracks[track].clips[index], tracks[track].clips[index + 1])
        guard let file = files[a.file] else { return nil }
        let lowest = max(a.minimumLength - a.length, b.crossfades.start.half - b.offset)
        let highest = min(
            file.length - a.offset - a.length - a.crossfades.end.half, b.length - b.minimumLength)
        return lowest...highest
    }

    /// The deltas that `slip` accepts for the clip: the crossfade half at the start edge stays in the
    /// file, and so does the end of the clip plus the crossfade half at its end. Throws `.unknownClip`.
    public func slipLimits(_ id: ClipID) throws(SessionError) -> ClosedRange<Frames> {
        guard let clip = clip(id)?.clip else { throw .unknownClip(id) }
        guard let file = files[clip.file] else { throw .unknownFile(clip.file) }
        let lowest = clip.crossfades.start.half - clip.offset
        let highest = file.length - clip.offset - clip.length - clip.crossfades.end.half
        return lowest...highest
    }

    /// Moves the join between the clip `left` and the clip that touches its end by `delta` frames
    /// (decision 0036): the left clip grows by `delta` and the right clip loses `delta` at its start,
    /// and its offset follows. No other clip and no marker moves. Both clips keep their crossfades,
    /// so the join keeps its crossfade, and the fade at each side of the join yields to the room
    /// (decision 0035). A delta of 0 changes nothing. A clip with no touching clip after it throws
    /// `.noJoin`, an unknown clip `.unknownClip`, and a delta past `rollLimits` the error of `check`.
    /// A throw changes nothing.
    public mutating func roll(_ left: ClipID, by delta: Frames) throws(SessionError) {
        guard delta >= .zero - .limit, delta <= .limit else { throw .frameOutOfRange }
        let (track, index) = try position(of: left)
        guard tracks[track].clips.join(after: index) != .none else { throw .noJoin(left) }
        guard delta != .zero else { return }
        let (a, b) = (tracks[track].clips[index], tracks[track].clips[index + 1])
        var newA = a
        newA.length = a.length + delta
        newA.fades = newA.fitting(a.fades, keeping: .start)
        var newB = b
        newB.start = b.start + delta
        newB.offset = b.offset + delta
        newB.length = b.length - delta
        newB.fades = newB.fitting(b.fades, keeping: .end)
        try check(newA, on: tracks[track])
        try check(newB, on: tracks[track])
        tracks[track].clips.replace([(index, newA), (index + 1, newB)])
    }

    /// Adds `delta` to the file offset of each clip: the audio moves under the clip, and the start,
    /// the length, the gain, the fades, the crossfades, and the gain points stay (the points are file
    /// frames, decision 0060). A delta of 0 changes nothing. An unknown ID throws `.unknownClip`, and
    /// a delta past `slipLimits` of any clip the error of `check`. A throw changes nothing.
    public mutating func slip(_ ids: [ClipID], by delta: Frames) throws(SessionError) {
        guard delta >= .zero - .limit, delta <= .limit else { throw .frameOutOfRange }
        let slipping = Set(ids)
        var lanes = tracks
        var found = 0
        for track in lanes.indices {
            var edits: [(index: Int, clip: Clip)] = []
            for (index, clip) in lanes[track].clips.enumerated() where slipping.contains(clip.id) {
                var slipped = clip
                slipped.offset = clip.offset + delta
                try check(slipped, on: lanes[track])
                edits.append((index, slipped))
            }
            found += edits.count
            if delta != .zero { lanes[track].clips.replace(edits) }
        }
        if found < slipping.count, let missing = ids.first(where: { clip($0) == nil }) { throw .unknownClip(missing) }
        tracks = lanes
    }
}

extension Clip {
    /// The least length that `Session.check` accepts: one frame, and both crossfade halves.
    fileprivate var minimumLength: Frames { max(Frames(1), crossfades.start.half + crossfades.end.half) }
}
