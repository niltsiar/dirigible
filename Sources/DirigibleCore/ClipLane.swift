import Foundation

/// The clips of one track, sorted by start. No two clips overlap. Each crossfade has its partner
/// (decision 0036): a touching neighbor with the same length.
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

    /// The join of the clips at `left` and `left + 1` (decision 0036).
    enum Join { case none, seamless, butt }

    /// `.none` when no clip is at `left` or `left + 1`, or the two clips do not touch.
    func join(after left: Int) -> Join {
        guard left >= 0, left + 1 < storage.count, storage[left].end == storage[left + 1].start else { return .none }
        return storage[left].isSeamless(with: storage[left + 1]) ? .seamless : .butt
    }

    /// The fault of the crossfade at the join of the clips at `left` and `left + 1`, named for
    /// `id`; nil when the join holds it.
    private func joinFault(_ left: Int, id: ClipID) -> SessionError? {
        guard join(after: left) != .none, storage[left].crossfades.end == storage[left + 1].crossfades.start else {
            return .crossfadeWithoutJoin(id)
        }
        return nil
    }

    /// The clip at `index` as it sounds (`Clip.sounding`), and the curve of each edge: linear for a
    /// crossfade at a seamless join (equal gain), else sine.
    public func sounding(at index: Int) -> SoundingClip {
        let clip = storage[index]
        func curve(_ length: Frames, after left: Int) -> Fades.Curve {
            length != .zero && join(after: left) == .seamless ? .linear : .sine
        }
        return SoundingClip(
            clip: clip.sounding,
            curves: Fades.Curves(
                start: curve(clip.crossfades.start, after: index - 1), end: curve(clip.crossfades.end, after: index)))
    }

    /// The sounding clips whose sounding range has at least one frame in `range` (the render).
    public func sounding(in range: Range<Frames>) -> [SoundingClip] {
        storage.indices.filter { storage[$0].soundingRange.overlaps(range) }.map(sounding(at:))
    }

    /// The left clip of the first seamless join with a crossfade: `fileVersion` 9, and the refusal
    /// of a file of version 8 or lower.
    var seamlessCrossfade: ClipID? {
        storage.indices.first { storage[$0].crossfades.end != .zero && join(after: $0) == .seamless }
            .map { storage[$0].id }
    }

    /// Drops each crossfade of the clips in `indices` whose join does not hold it.
    private mutating func repair(_ indices: Range<Int>) {
        for index in indices.clamped(to: storage.indices) where storage[index].crossfades != .zero {
            let id = storage[index].id
            let old = storage[index].crossfades
            let new = Crossfades(
                valid: joinFault(index - 1, id: id) == nil ? old.start : .zero,
                end: joinFault(index, id: id) == nil ? old.end : .zero)
            if new != old { storage[index].crossfades = new }
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
    /// least one frame in `range`. `checkMedia` and `shiftedFrames` read it, so a clip that sounds
    /// in a range from its handle is found.
    public func clips(soundingIn range: Range<Frames>) -> [Clip] {
        storage.filter { $0.soundingRange.overlaps(range) }
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

    /// Merges clips that are sorted by start and do not overlap the lane or each other. It repairs
    /// only the joins next to each inserted clip: the lane is paired before the edit (0036).
    mutating func insert(sorted clips: [Clip]) {
        var merged: [Clip] = []
        merged.reserveCapacity(storage.count + clips.count)
        var inserted: [Int] = []
        var (i, j) = (0, 0)
        while i < storage.count || j < clips.count {
            if j == clips.count || (i < storage.count && storage[i].start < clips[j].start) {
                merged.append(storage[i])
                i += 1
            } else {
                inserted.append(merged.count)
                merged.append(clips[j])
                j += 1
            }
        }
        assert(zip(merged, merged.dropFirst()).allSatisfy { $0.end <= $1.start }, "An insert overlaps a clip")
        storage = merged
        // The lane held its pairing before, so only the joins next to an inserted clip can change.
        for index in inserted { repair((index - 1)..<(index + 2)) }
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

    /// The index of the clip that `frame` cuts: `start < frame < end`. A frame at a clip edge or in
    /// a gap cuts nothing.
    public func index(cutting frame: Frames) -> Int? {
        index(holding: frame).flatMap { storage[$0].start < frame ? $0 : nil }
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

    /// Only the joins of the two new neighbors can change: the lane is paired before the edit (0036).
    mutating func remove(at index: Int) {
        storage.remove(at: index)
        repair((index - 1)..<(index + 1))
    }

    /// True when the clips at `left` and `left + 1` touch and play on in one file at one gain at
    /// each frame, the envelope included, with no fade at the join: one clip over both plays the
    /// same samples, and so does a crossfade of any length there (Command-F skips the join). The
    /// envelopes compare on the file frames that the joined clip plays, its crossfade halves too
    /// (decision 0060).
    package func canHeal(after left: Int) -> Bool {
        guard join(after: left) == .seamless else { return false }
        let (a, b) = (storage[left], storage[left + 1])
        guard a.gain == b.gain, a.fades.fadeOut == .zero, b.fades.fadeIn == .zero else { return false }
        let first = a.offset - a.crossfades.start.half
        let last = b.offset + b.length + b.crossfades.end.half - Frames(1)
        return a.envelope.hasEqualGain(to: b.envelope, in: first...last)
    }

    /// True when a new crossfade at the join after `left` changes no sample: `canHeal(after:)`, and
    /// the join has no crossfade. `setCrossfades` refuses a new crossfade there, and
    /// `crossfadeLimit` is 0.
    func newCrossfadeChangesNoSample(after left: Int) -> Bool {
        canHeal(after: left) && storage[left].crossfades.end == .zero
    }

    /// Joins the clip at `index` and the clip after it, which `canHeal(after:)` approved. The clip
    /// keeps its ID, its start edge, and the fade-in and start crossfade; the right clip gives the end
    /// edge, and the points of each clip on its side of the join. The neighbors still touch the same
    /// edges, so their crossfades stay paired.
    mutating func heal(at index: Int) {
        var clip = storage[index]
        let right = storage.remove(at: index + 1)
        clip.length = clip.length + right.length
        clip.envelope = .joined(clip.envelope, right.envelope, at: right.offset)
        clip.fades = Fades(fadeIn: clip.fades.fadeIn, fadeOut: right.fades.fadeOut)!
        clip.crossfades = Crossfades(valid: clip.crossfades.start, end: right.crossfades.end)
        storage[index] = clip
        repair((index - 1)..<(index + 2))
    }

    /// Moves each clip that starts at or after `frame` by `offset` (a ripple, decision 0037). The
    /// caller checks that the moved clips do not overlap the clip before them and that their ends
    /// stay in range. The joins inside the moved part stay paired, so only the join at the edge of
    /// the move can change (0036).
    mutating func shift(from frame: Frames, by offset: Frames) {
        guard offset != .zero, let first = storage.firstIndex(where: { $0.start >= frame }) else { return }
        for index in first..<storage.count { storage[index].start = storage[index].start + offset }
        assert(first == 0 || storage[first - 1].end <= storage[first].start, "A shift overlaps a clip")
        repair((first - 1)..<(first + 1))
    }

    /// Replaces the clip at `index` with `clip`, which has the same start, and moves each later
    /// clip by the change of its end (a ripple trim, decision 0037). The caller checks the ends.
    /// The later clips move whole, so only the joins of the clip can change (0036).
    mutating func ripple(at index: Int, with clip: Clip) {
        let offset = clip.end - storage[index].end
        storage[index] = clip
        for later in (index + 1)..<storage.count { storage[later].start = storage[later].start + offset }
        repair((index - 1)..<(index + 2))
    }

    /// One clip changes and no clip moves, so only the joins of its neighbors can break.
    mutating func replace(at index: Int, with clip: Clip) {
        storage[index] = clip
        repair((index - 1)..<(index + 2))
    }

    /// Replaces several clips in place, sorted by index, then repairs once: both clips of a new
    /// crossfade change before the repair reads their join.
    mutating func replace(_ clips: [(index: Int, clip: Clip)]) {
        guard let low = clips.first?.index, let high = clips.last?.index else { return }
        for (index, clip) in clips { storage[index] = clip }
        repair((low - 1)..<(high + 2))
    }
}

extension Clip {
    /// The part of the clip in `range`, which is inside the clip. The offset follows the start. The
    /// part keeps the fade of each edge that it keeps (decision 0035), and the crossfade of each
    /// edge that it keeps when its half fits the room of that edge (decision 0036).
    func cut(to range: Range<Frames>, id: ClipID) -> Clip {
        var part = Clip(
            id: id, file: file, start: range.lowerBound, offset: offset + (range.lowerBound - start),
            length: range.upperBound - range.lowerBound, gain: gain, fades: fades.cut(range, of: self.range),
            envelope: envelope)
        let kept = Crossfades.kept(edgesOf: self, in: range)
        part.crossfades = kept
        part.crossfades = Crossfades(
            valid: kept.start.half <= part.room(.start) ? kept.start : .zero,
            end: kept.end.half <= part.room(.end) ? kept.end : .zero)
        return part
    }
}
