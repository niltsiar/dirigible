import Foundation

/// Crossfades at a butt join (decision 0036).
extension Session {
    /// Sets the crossfade at the end of each clip (the key) and at the start of its right neighbor,
    /// in one pass over the lanes. 0 removes it. A new crossfade sets the fades at its two edges to
    /// 0, and the fade at the other edge of each clip yields. A clip with no touching neighbor
    /// throws `.crossfadeWithoutJoin`, a seamless join `.crossfadeAtSeamlessJoin`, and a length
    /// that `Crossfades` refuses `.frameOutOfRange`. A throw changes nothing.
    public mutating func setCrossfades(_ lengths: [ClipID: Frames]) throws(SessionError) {
        var lanes = tracks
        var found = 0
        for track in lanes.indices where found < lengths.count {
            let owner = lanes[track]
            let lane = owner.clips
            // The changed clips in index order: only the right clip of the join before can change
            // again, so the list needs no dictionary and no sort (bench B2 of run 11c-2).
            var changed: [(index: Int, clip: Clip)] = []
            for (index, clip) in lane.enumerated() {
                guard let length = lengths[clip.id] else { continue }
                found += 1
                var left = changed.last?.index == index ? changed.removeLast().clip : clip
                let join = lane.join(after: index)
                guard join != .none else { throw .crossfadeWithoutJoin(left.id) }
                if length != .zero, join == .seamless { throw .crossfadeAtSeamlessJoin(left.id) }
                var right = lane[index + 1]
                guard let end = Crossfades(start: left.crossfades.start, end: length),
                    let start = Crossfades(start: length, end: right.crossfades.end)
                else { throw .frameOutOfRange }
                (left.crossfades, right.crossfades) = (end, start)
                if length != .zero {
                    left.fades = left.fitting(Fades(fadeIn: left.fades.fadeIn, fadeOut: .zero)!, keeping: .end)
                    right.fades = right.fitting(Fades(fadeIn: .zero, fadeOut: right.fades.fadeOut)!, keeping: .start)
                }
                changed.append((index, left))
                changed.append((index + 1, right))
                if found == lengths.count { break }
            }
            for (_, clip) in changed { try check(clip, on: owner) }
            lanes[track].clips.replace(changed)
        }
        if found < lengths.count, let missing = lengths.keys.sorted().first(where: { clip($0) == nil }) {
            throw .unknownClip(missing)
        }
        tracks = lanes
    }

    /// The longest crossfade at the join after the clip at `left` of `lane`: 2 x the least of the
    /// handle after that clip, the handle before its neighbor, and the room of each clip beside the
    /// crossfade half at its other edge (its fades yield). 0 at a seamless join. Nil with no
    /// touching neighbor or no pool file. The index makes it constant time, so Command-F on Select
    /// All reads it for each join with no clip search.
    public func crossfadeLimit(after left: Int, in lane: ClipLane) -> Frames? {
        let join = lane.join(after: left)
        guard join != .none, let file = files[lane[left].file] else { return nil }
        if join == .seamless { return .zero }
        let (a, b) = (lane[left], lane[left + 1])
        let half = min(
            file.length - (a.offset + a.length), b.offset, a.crossfadeRoom(.end), b.crossfadeRoom(.start))
        return Frames(2 * max(0, half.count))
    }
}
