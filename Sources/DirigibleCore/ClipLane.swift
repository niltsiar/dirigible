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
        clear(clip.range, rightID: rightID)
        insert(clip)
    }

    /// Removes the frames in `range` and leaves a gap. A clip that covers the whole range on
    /// both sides becomes two clips; `rightID` names the right one from the clip and its new start.
    mutating func clear(_ range: Range<Frames>, rightID: (Clip, Frames) -> ClipID) {
        guard !range.isEmpty else { return }
        var kept: [Clip] = []
        for clip in storage {
            guard clip.range.overlaps(range) else {
                kept.append(clip)
                continue
            }
            if clip.start < range.lowerBound {
                kept.append(clip.cut(to: clip.start..<range.lowerBound, id: clip.id))
            }
            if clip.end > range.upperBound {
                let id = clip.start < range.lowerBound ? rightID(clip, range.upperBound) : clip.id
                kept.append(clip.cut(to: range.upperBound..<clip.end, id: id))
            }
        }
        storage = kept
    }

    /// Splits the clip at `frame`, which is inside the clip, not at an edge.
    mutating func split(at index: Int, frame: Frames, rightID: ClipID) {
        let clip = storage[index]
        storage[index] = clip.cut(to: clip.start..<frame, id: clip.id)
        storage.insert(clip.cut(to: frame..<clip.end, id: rightID), at: index + 1)
    }

    mutating func remove(at index: Int) -> Clip {
        storage.remove(at: index)
    }

    mutating func replace(at index: Int, with clip: Clip) {
        storage[index] = clip
    }

    mutating func insert(_ clip: Clip) {
        let index = storage.firstIndex { $0.start > clip.start } ?? storage.endIndex
        storage.insert(clip, at: index)
    }
}

extension Clip {
    /// The part of the clip in `range`, which is inside the clip. The offset follows the start.
    func cut(to range: Range<Frames>, id: ClipID) -> Clip {
        Clip(
            id: id, file: file, start: range.lowerBound, offset: offset + (range.lowerBound - start),
            length: range.upperBound - range.lowerBound, gain: gain)
    }
}
