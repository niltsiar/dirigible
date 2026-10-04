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
        for track in lanes.indices {
            let lane = lanes[track].clips
            var changed: [Int: Clip] = [:]
            for index in lane.indices {
                guard let length = lengths[lane[index].id] else { continue }
                found += 1
                var left = changed[index] ?? lane[index]
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
                (changed[index], changed[index + 1]) = (left, right)
            }
            for index in changed.keys.sorted() { try check(changed[index]!, on: lanes[track]) }
            lanes[track].clips.replace(changed)
        }
        if found < lengths.count, let missing = lengths.keys.sorted().first(where: { clip($0) == nil }) {
            throw .unknownClip(missing)
        }
        tracks = lanes
    }

    /// The longest crossfade at the end of `left`: 2 x the least of the handle after `left`, the
    /// handle before its neighbor, and the room of each clip beside the crossfade half at its other
    /// edge (its fades yield). 0 at a seamless join. Nil with no touching neighbor.
    public func crossfadeLimit(after left: ClipID) -> Frames? {
        guard let (track, index) = try? position(of: left) else { return nil }
        let lane = tracks[track].clips
        let join = lane.join(after: index)
        guard join != .none, let file = files[lane[index].file] else { return nil }
        if join == .seamless { return .zero }
        let (a, b) = (lane[index], lane[index + 1])
        let half = min(
            file.length - (a.offset + a.length), b.offset, a.crossfadeRoom(.end), b.crossfadeRoom(.start))
        return Frames(2 * max(0, half.count))
    }
}
