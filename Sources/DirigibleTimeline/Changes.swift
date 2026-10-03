import DirigibleCore
import Foundation

/// The frames and the lanes where the clips or the markers of `new` differ from those of `old`:
/// from the start of the first changed clip to the end of the last one, with the unchanged lane
/// neighbor whose join to a changed clip comes or goes at an edge with no fade (its fade handle),
/// on the first to the last changed lane, and the old and the new frame of each changed marker
/// (its line crosses every lane). Nil when another value that the lanes draw differs: the tracks, their gain or layout, or
/// the files (the labels). So a drag event redraws the boxes and lines that it changed, not the
/// lanes in view (decision 0020). A lane with no change costs one compare of its clip storage.
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
        // A lane is in order and has no overlap: the first and the last changed clip give the frames.
        let (before, after) = (
            x[(x.startIndex + head)..<(x.endIndex - tail)], y[(y.startIndex + head)..<(y.endIndex - tail)]
        )
        guard var start = [before.first?.start, after.first?.start].compactMap({ $0 }).min(),
            var end = [before.last?.end, after.last?.end].compactMap({ $0 }).max()
        else { continue }
        // The unchanged neighbors just before and after the run: a fade handle of an edge with no
        // fade shows only with no join, so a join that comes or goes redraws that neighbor.
        if head > 0 {
            let left = y[y.startIndex + head - 1]
            if left.fades.fadeOut == .zero, (before.first?.start == left.end) != (after.first?.start == left.end) {
                start = left.start
            }
        }
        if tail > 0 {
            let right = y[y.endIndex - tail]
            if right.fades.fadeIn == .zero, (before.last?.end == right.start) != (after.last?.end == right.start) {
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
    /// Whether a lane neighbor touches the clip at `index` (a butt join). Command-F, the fade
    /// handles, and `changedFrames` read it (decision 0035).
    func joins(at index: Int) -> (before: Bool, after: Bool) {
        let clip = self[index]
        return (
            index > startIndex && self[index - 1].end == clip.start,
            index + 1 < endIndex && self[index + 1].start == clip.end
        )
    }
}
