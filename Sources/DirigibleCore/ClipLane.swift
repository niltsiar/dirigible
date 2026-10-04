import Foundation

/// The clips of one track, sorted by start. No two clips overlap. Each crossfade has its partner
/// (decision 0036): a touching neighbor with the same length at a join that is not seamless.
/// The mutators are internal: `Session` adds the checks that need the file pool. Each mutator ends
/// with a repair that drops a crossfade whose join the edit broke, on both clips.
public struct ClipLane: RandomAccessCollection, Hashable, Sendable {
    private var storage: [Clip] = []

    init() {}

    /// Sorts the clips, and refuses two clips that overlap and a crossfade with no partner.
    init(validating clips: [Clip]) throws(SessionError) {
        storage = clips.sorted { $0.start < $1.start }
        for (left, right) in zip(storage, storage.dropFirst()) where right.start < left.end {
            throw .overlap(right.id, left.id)
        }
        for index in storage.indices {
            let clip = storage[index]
            if clip.crossfades.start != .zero, let fault = joinFault(index - 1, id: clip.id) { throw fault }
            if clip.crossfades.end != .zero, let fault = joinFault(index, id: clip.id) { throw fault }
        }
    }

    /// The fault of the crossfade at the join of the clips at `left` and `left + 1`, named for
    /// `id`; nil when the join holds it.
    private func joinFault(_ left: Int, id: ClipID) -> SessionError? {
        guard left >= 0, left + 1 < storage.count else { return .crossfadeWithoutJoin(id) }
        let (a, b) = (storage[left], storage[left + 1])
        guard a.end == b.start, a.crossfades.end == b.crossfades.start else { return .crossfadeWithoutJoin(id) }
        return a.isSeamless(with: b) ? .crossfadeAtSeamlessJoin(id) : nil
    }

    /// Drops each crossfade of the clips in `indices` whose join does not hold it.
    private mutating func repair(_ indices: Range<Int>) {
        for index in indices.clamped(to: storage.indices) where storage[index].crossfades != .zero {
            let id = storage[index].id
            let old = storage[index].crossfades
            let start = joinFault(index - 1, id: id) == nil ? old.start : .zero
            let end = joinFault(index, id: id) == nil ? old.end : .zero
            if start != old.start || end != old.end { storage[index].crossfades = Crossfades(start: start, end: end)! }
        }
    }

    public var startIndex: Int { storage.startIndex }
    public var endIndex: Int { storage.endIndex }
    public subscript(index: Int) -> Clip { storage[index] }

    /// The clips that have at least one frame in `range`.
    public func clips(overlapping range: Range<Frames>) -> [Clip] {
        storage.filter { $0.range.overlaps(range) }
    }

    /// The clips whose sounding range (decision 0036: the clip plus half of each crossfade) has at
    /// least one frame in `range`. The render, the media check, and the draw read it, so a clip
    /// that sounds in a range from its handle is found.
    public func clips(soundingIn range: Range<Frames>) -> [Clip] {
        storage.filter { $0.sounding.range.overlaps(range) }
    }

    /// Clears the range of the clip, then inserts the clip (Hindenburg paste).
    mutating func overwrite(with clip: Clip, rightID: (Clip, Frames) -> ClipID) {
        clear([clip.range], rightID: rightID)
        insert(sorted: [clip])
    }

    /// Removes the frames in `ranges` and leaves gaps, in one pass. The ranges are sorted and do
    /// not overlap. The first part of a cut clip keeps its ID; `rightID` names each other part from
    /// the clip and the start of the part.
    mutating func clear(_ ranges: [Range<Frames>], rightID: (Clip, Frames) -> ClipID) {
        let ranges = ranges.filter { !$0.isEmpty }
        guard !ranges.isEmpty else { return }
        var kept: [Clip] = []
        var next = 0
        for clip in storage {
            while next < ranges.count, ranges[next].upperBound <= clip.start { next += 1 }
            var start = clip.start
            var first = true
            for range in ranges[next...] {
                guard range.lowerBound < clip.end else { break }
                if start < range.lowerBound {
                    kept.append(clip.cut(to: start..<range.lowerBound, id: first ? clip.id : rightID(clip, start)))
                    first = false
                }
                start = Swift.max(start, range.upperBound)
            }
            if start < clip.end {
                kept.append(clip.cut(to: start..<clip.end, id: first ? clip.id : rightID(clip, start)))
            }
        }
        storage = kept
        repair(storage.indices)
    }

    /// Merges clips that are sorted by start and do not overlap the lane or each other.
    mutating func insert(sorted clips: [Clip]) {
        var merged: [Clip] = []
        merged.reserveCapacity(storage.count + clips.count)
        var (i, j) = (0, 0)
        while i < storage.count || j < clips.count {
            if j == clips.count || (i < storage.count && storage[i].start < clips[j].start) {
                merged.append(storage[i])
                i += 1
            } else {
                merged.append(clips[j])
                j += 1
            }
        }
        assert(zip(merged, merged.dropFirst()).allSatisfy { $0.end <= $1.start }, "An insert overlaps a clip")
        storage = merged
        repair(storage.indices)
    }

    /// The index of the clip with `start <= frame < end`, by binary search.
    public func index(holding frame: Frames) -> Int? {
        var (low, high) = (0, storage.count)
        while low < high {
            let middle = (low + high) / 2
            if storage[middle].start <= frame { low = middle + 1 } else { high = middle }
        }
        return low > 0 && frame < storage[low - 1].end ? low - 1 : nil
    }

    mutating func remove(ids: Set<ClipID>) {
        storage.removeAll { ids.contains($0.id) }
        repair(storage.indices)
    }

    /// Splits the clip at `frame`, which is inside the clip, not at an edge.
    mutating func split(at index: Int, frame: Frames, rightID: ClipID) {
        let clip = storage[index]
        storage[index] = clip.cut(to: clip.start..<frame, id: clip.id)
        storage.insert(clip.cut(to: frame..<clip.end, id: rightID), at: index + 1)
        repair(storage.indices)
    }

    mutating func remove(at index: Int) {
        storage.remove(at: index)
        repair(storage.indices)
    }

    /// One clip changes and no clip moves, so only the joins of its neighbors can break.
    mutating func replace(at index: Int, with clip: Clip) {
        storage[index] = clip
        repair((index - 1)..<(index + 2))
    }

    /// Replaces several clips in place, then repairs once: both clips of a new crossfade change
    /// before the repair reads their join.
    mutating func replace(_ clips: [Int: Clip]) {
        for (index, clip) in clips { storage[index] = clip }
        for index in clips.keys { repair((index - 1)..<(index + 2)) }
    }
}

extension Clip {
    /// The part of the clip in `range`, which is inside the clip. The offset follows the start. The
    /// part keeps the fade of each edge that it keeps (decision 0035), and the crossfade of each
    /// edge that it keeps when its half fits the room of that edge (decision 0036).
    func cut(to range: Range<Frames>, id: ClipID) -> Clip {
        var part = Clip(
            id: id, file: file, start: range.lowerBound, offset: offset + (range.lowerBound - start),
            length: range.upperBound - range.lowerBound, gain: gain, fades: fades.cut(range, of: self.range))
        part.crossfades = Crossfades(
            start: range.lowerBound == start ? crossfades.start : .zero,
            end: range.upperBound == end ? crossfades.end : .zero)!
        part.crossfades = Crossfades(
            start: part.crossfades.start.half <= part.room(.start) ? part.crossfades.start : .zero,
            end: part.crossfades.end.half <= part.room(.end) ? part.crossfades.end : .zero)!
        return part
    }
}
