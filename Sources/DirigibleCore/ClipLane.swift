import Foundation

/// The clips of one track, sorted by start. No two clips overlap.
/// The mutators are internal: `Session` adds the checks that need the file pool.
public struct ClipLane: RandomAccessCollection, Hashable, Sendable {
    private var storage: [Clip] = []

    init() {}

    /// Sorts the clips and refuses two clips that overlap.
    init(validating clips: [Clip]) throws(SessionError) {
        storage = clips.sorted { $0.start < $1.start }
        for (left, right) in zip(storage, storage.dropFirst()) where right.start < left.end {
            throw .overlap(right.id, left.id)
        }
    }

    public var startIndex: Int { storage.startIndex }
    public var endIndex: Int { storage.endIndex }
    public subscript(index: Int) -> Clip { storage[index] }

    /// The clips that have at least one frame in `range`.
    public func clips(overlapping range: Range<Frames>) -> [Clip] {
        storage.filter { $0.range.overlaps(range) }
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
    }

    /// Splits the clip at `frame`, which is inside the clip, not at an edge.
    mutating func split(at index: Int, frame: Frames, rightID: ClipID) {
        let clip = storage[index]
        storage[index] = clip.cut(to: clip.start..<frame, id: clip.id)
        storage.insert(clip.cut(to: frame..<clip.end, id: rightID), at: index + 1)
    }

    mutating func remove(at index: Int) {
        storage.remove(at: index)
    }

    mutating func replace(at index: Int, with clip: Clip) {
        storage[index] = clip
    }
}

extension Clip {
    /// The part of the clip in `range`, which is inside the clip. The offset follows the start. The
    /// part keeps the fade of each edge that it keeps (decision 0035).
    func cut(to range: Range<Frames>, id: ClipID) -> Clip {
        Clip(
            id: id, file: file, start: range.lowerBound, offset: offset + (range.lowerBound - start),
            length: range.upperBound - range.lowerBound, gain: gain, fades: fades.cut(range, of: self.range))
    }
}
