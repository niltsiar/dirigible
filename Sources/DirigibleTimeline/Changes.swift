import DirigibleCore
import Foundation

/// The frames where the clips or the markers of `new` differ from those of `old`: from the start
/// of the first changed clip to the end of the last one, on any lane, and the old and the new
/// frame of each changed marker (its line crosses every lane). Nil when another value that the
/// lanes draw differs: the tracks, their gain or layout, or the files (the labels). So a drag event
/// redraws the boxes and lines that it changed, not the lanes in view (decision 0020, the dirty
/// rect upgrade path). A lane with no change costs one compare of its clip storage.
public func changedFrames(from old: Session, to new: Session) -> Range<Frames>? {
    guard old.tracks.count == new.tracks.count, old.files == new.files else { return nil }
    var changed: Range<Frames>?
    func add(_ start: Frames, _ end: Frames) {
        changed = min(changed?.lowerBound ?? start, start)..<max(changed?.upperBound ?? end, end)
    }
    if old.markers != new.markers {
        for id in Set(old.markers.keys).union(new.markers.keys) where old.markers[id] != new.markers[id] {
            for position in [old.markers[id]?.position, new.markers[id]?.position].compactMap({ $0 }) {
                add(position, position + Frames(1))
            }
        }
    }
    for (a, b) in zip(old.tracks, new.tracks) {
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
        guard let start = [before.first?.start, after.first?.start].compactMap({ $0 }).min(),
            let end = [before.last?.end, after.last?.end].compactMap({ $0 }).max()
        else { continue }
        add(start, end)
    }
    return changed ?? .zero ..< .zero
}
