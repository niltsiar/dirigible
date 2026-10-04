import DirigibleCore
import Foundation

/// The frames and the lanes where the clips or the markers of `new` differ from those of `old`:
/// from the sounding start of the first changed clip to the sounding end of the last one (the clip
/// and the outer half of each crossfade, decision 0036), with the unchanged lane neighbor whose
/// join to a changed clip comes or goes at an edge with no fade (its fade handle), on the first to
/// the last changed lane, and the old and the new frame of each changed marker (its line crosses
/// every lane). Nil when another value that the lanes draw differs: the tracks, their gain or
/// layout, or the files (the labels). So a drag event redraws the boxes and lines that it changed,
/// not the lanes in view (decision 0020). A lane with no change costs one compare of its clip
/// storage.
public func changedFrames(from old: Session, to new: Session) -> (frames: Range<Frames>, lanes: Range<Int>)? {
    guard old.tracks.count == new.tracks.count, old.files == new.files else { return nil }
    var changed: Range<Frames>?
    var lanes: Range<Int>?
    func add(_ start: Frames, _ end: Frames, lanes new: Range<Int>) {
        changed = hull(changed, start, end)
        lanes = min(lanes?.lowerBound ?? new.lowerBound, new.lowerBound)..<max(lanes?.upperBound ?? 0, new.upperBound)
    }
    if old.markers != new.markers {
        for id in Set(old.markers.keys).union(new.markers.keys) where old.markers[id] != new.markers[id] {
            for position in [old.markers[id]?.position, new.markers[id]?.position].compactMap({ $0 }) {
                add(position, position + Frames(1), lanes: 0..<new.tracks.count)
            }
        }
    }
    for (lane, (a, b)) in zip(old.tracks, new.tracks).enumerated() {
        guard a.id == b.id, a.gain == b.gain, a.layout == b.layout else { return nil }
        let (x, y) = (a.clips, b.clips)
        guard x != y else { continue }
        // The equal clips at the start and at the end of the lane do not change.
        let common = min(x.count, y.count)
        var (head, tail) = (0, 0)
        while head < common, x[x.startIndex + head] == y[y.startIndex + head] { head += 1 }
        while tail < common - head, x[x.endIndex - 1 - tail] == y[y.endIndex - 1 - tail] { tail += 1 }
        // A lane is in order and has no overlap: the first and the last changed clip give the frames,
        // with the half of a crossfade outside the clip, where its fade line draws (decision 0036).
        let (before, after) = (
            x[(x.startIndex + head)..<(x.endIndex - tail)], y[(y.startIndex + head)..<(y.endIndex - tail)]
        )
        guard var start = [before.first?.sounding.start, after.first?.sounding.start].compactMap({ $0 }).min(),
            var end = [before.last?.sounding.end, after.last?.sounding.end].compactMap({ $0 }).max()
        else { continue }
        // The unchanged neighbors just before and after the run: a fade handle of an edge with no
        // fade and no crossfade shows only with no join, so a join that comes or goes redraws that
        // neighbor.
        if head > 0 {
            let left = y[y.startIndex + head - 1]
            let (wasJoined, isJoined) = (before.first?.start == left.end, after.first?.start == left.end)
            if LaneGeometry.hasHandle(fade: left.fades.fadeOut, crossfade: left.crossfades.end, joined: wasJoined)
                != LaneGeometry.hasHandle(fade: left.fades.fadeOut, crossfade: left.crossfades.end, joined: isJoined)
            {
                start = left.start
            }
        }
        if tail > 0 {
            let right = y[y.endIndex - tail]
            let (wasJoined, isJoined) = (before.last?.end == right.start, after.last?.end == right.start)
            if LaneGeometry.hasHandle(fade: right.fades.fadeIn, crossfade: right.crossfades.start, joined: wasJoined)
                != LaneGeometry.hasHandle(fade: right.fades.fadeIn, crossfade: right.crossfades.start, joined: isJoined)
            {
                end = right.end
            }
        }
        add(start, end, lanes: lane..<lane + 1)
    }
    return (changed ?? .zero ..< .zero, lanes ?? 0..<0)
}

/// The frames where the Marks `new` draw differently from `old` on the lanes of `session`: the old
/// and the new line of each changed point, and the changed part of the selection band. With the
/// same selected tracks, the band changes only between the old and the new frame of a point, and
/// the lines of that point hold them; with other tracks, both bands change. So a range drag or a
/// triangle drag redraws those columns, not the lanes in view. Empty when nothing changed.
public func changedFrames(from old: Marks, to new: Marks, in session: Session) -> Range<Frames> {
    var changed: Range<Frames>?
    for (a, b) in [(old.inPoint, new.inPoint), (old.outPoint, new.outPoint)] where a != b {
        for point in [a, b].compactMap({ $0 }) { changed = hull(changed, point, point + Frames(1)) }
    }
    let (x, y) = (old.selection(in: session), new.selection(in: session))
    if x?.tracks != y?.tracks {
        for band in [x?.range, y?.range].compactMap({ $0 }) {
            changed = hull(changed, band.lowerBound, band.upperBound)
        }
    }
    return changed ?? .zero ..< .zero
}

/// The smallest range that holds `range` and `start ..< end`.
private func hull(_ range: Range<Frames>?, _ start: Frames, _ end: Frames) -> Range<Frames> {
    min(range?.lowerBound ?? start, start)..<max(range?.upperBound ?? end, end)
}

extension ClipLane {
    /// Whether a lane neighbor touches the clip at `index` (a butt join). Command-F and the fade
    /// handles read it (decision 0035); `changedFrames` compares the joins of a changed run with
    /// `LaneGeometry.hasHandle`.
    func joins(at index: Int) -> (before: Bool, after: Bool) {
        let clip = self[index]
        return (
            index > startIndex && self[index - 1].end == clip.start,
            index + 1 < endIndex && self[index + 1].start == clip.end
        )
    }
}

/// The result of `shiftedFrames`.
public typealias ShiftedFrames = (from: Frames, delta: Frames, strays: [Frames])

/// The part of the lanes that `new` draws as `old` moved by `delta` frames (a ripple, decision
/// 0037): on every lane, each clip that sounds at `from` or later starts there or later and is a
/// clip of `old` moved by `delta`. The draw then copies those pixels and draws the frames before
/// `from` and the marker lines in `strays`: the new line and the moved old line of each marker
/// at `from` or later that does not move by `delta` (a marker that a ripple delete stops at the
/// range start). `from` is the sounding start of the first moved clip of the lane where it is the
/// latest, or its sounding end when its join to the clip before it comes or goes. Nil when no lane moves its last clip, or when the rule does not hold: the lanes then
/// draw in full.
public func shiftedFrames(from old: Session, to new: Session) -> ShiftedFrames? {
    guard old.tracks.count == new.tracks.count else { return nil }
    func moved(_ clip: Clip, by delta: Frames) -> Clip {
        var clip = clip
        clip.start = clip.start + delta
        return clip
    }
    var delta: Frames?
    for (a, b) in zip(old.tracks, new.tracks) {
        guard let x = a.clips.last, let y = b.clips.last, x != y else { continue }
        let shift = y.start - x.start
        guard shift != .zero, moved(x, by: shift) == y, delta == nil || delta == shift else { return nil }
        delta = shift
    }
    guard let delta else { return nil }
    var from = Frames.zero
    for (a, b) in zip(old.tracks, new.tracks) {
        var (i, j) = (a.clips.endIndex - 1, b.clips.endIndex - 1)
        while i >= a.clips.startIndex, j >= b.clips.startIndex, moved(a.clips[i], by: delta) == b.clips[j] {
            (i, j) = (i - 1, j - 1)
        }
        guard j + 1 < b.clips.endIndex else { continue }
        // The fade handle of the first moved clip shows only with no join, so a join that comes or
        // goes puts that clip in the drawn part.
        let first = b.clips[j + 1]
        let joined = (j >= b.clips.startIndex && b.clips[j].end == first.start)
        let wasJoined = (i >= a.clips.startIndex && a.clips[i].end == a.clips[i + 1].start)
        from = max(from, joined == wasJoined ? first.sounding.start : first.sounding.end)
    }
    // The check of the rule at `from`, on each lane and for the markers.
    for (a, b) in zip(old.tracks, new.tracks) {
        let before = a.clips.clips(soundingIn: (from - delta)..<Frames.limit + Frames.limit)
        let after = b.clips.clips(soundingIn: from..<Frames.limit + Frames.limit)
        guard before.allSatisfy({ $0.sounding.start >= from - delta }), after.allSatisfy({ $0.sounding.start >= from }),
            before.map({ moved($0, by: delta) }) == after
        else { return nil }
    }
    var strays: [Frames] = []
    for id in Set(old.markers.keys).union(new.markers.keys) {
        let (a, b) = (old.markers[id], new.markers[id])
        let shifted = a.flatMap { $0.position >= from - delta ? $0.position + delta : nil }
        let late = b.flatMap { $0.position >= from ? $0.position : nil }
        guard shifted != nil || late != nil else { continue }
        if shifted == late, a?.kind == b?.kind { continue }
        strays += [shifted, late].compactMap { $0 }
    }
    return (from, delta, strays)
}
