import Foundation

/// A copy of timeline material: the parts of the clips in one range on some tracks. Only
/// `Session.excerpt` makes one, so each lane is sorted, has no overlap, and has clip starts
/// relative to the range start. Its file IDs name pool files of one package.
public struct Excerpt: Hashable, Sendable {
    public struct Lane: Hashable, Sendable {
        public let source: TrackID
        public let clips: [Clip]
    }

    public let length: Frames
    public let lanes: [Lane]
}

/// The edits of many clips (decision 0018). Each edit uses one set of taken clip IDs, so its cost
/// grows with the clip count, not with its square.
extension Session {
    /// The parts of the clips in `range` on each track, in the order of `tracks`. The edge clips
    /// are cut and keep their IDs.
    public func excerpt(of range: Range<Frames>, on tracks: [TrackID]) throws(SessionError) -> Excerpt {
        guard range.lowerBound.isInRange, range.upperBound.isInRange else { throw .frameOutOfRange }
        var lanes: [Excerpt.Lane] = []
        for id in tracks {
            let clips = self.tracks[try trackIndex(id)].clips.clips(overlapping: range).map { clip in
                var part = clip.cut(
                    to: max(clip.start, range.lowerBound)..<min(clip.end, range.upperBound), id: clip.id)
                part.start = part.start - range.lowerBound
                return part
            }
            lanes.append(Excerpt.Lane(source: id, clips: clips))
        }
        return Excerpt(length: range.upperBound - range.lowerBound, lanes: lanes)
    }

    /// Lane i goes to `tracks[i]`. The paste clears the whole block `start..<start + length` on
    /// the track, also under a gap of the excerpt, then adds the lane clips. A pasted clip gets
    /// the first free ID of "<source id>@<start>"; the right part of a cut clip gets
    /// "<id>@<block end>". Returns the pasted IDs, lane by lane. A throw changes nothing.
    @discardableResult
    public mutating func paste(_ excerpt: Excerpt, at start: Frames, on tracks: [TrackID]) throws(SessionError)
        -> [ClipID]
    {
        // One different track for each lane: a track given twice is a wrong count, not a used ID.
        guard tracks.count == excerpt.lanes.count, Set(tracks).count == tracks.count else {
            throw .trackCount(excerpt.lanes.count)
        }
        // Both values are in 0...limit before the sum, so the sum cannot overflow.
        guard start.isInRange, excerpt.length.isInRange, (start + excerpt.length).isInRange else {
            throw .frameOutOfRange
        }
        let block = start..<(start + excerpt.length)
        var copy = self
        var taken = clipIDs
        var pasted: [ClipID] = []
        for (lane, id) in zip(excerpt.lanes, tracks) {
            let index = try trackIndex(id)
            var clips: [Clip] = []
            for clip in lane.clips {
                let placed = Clip(
                    id: Self.derivedID(of: clip.id, at: start + clip.start, taken: &taken), file: clip.file,
                    start: start + clip.start, offset: clip.offset, length: clip.length, gain: clip.gain)
                try check(placed, on: self.tracks[index])
                clips.append(placed)
            }
            copy.tracks[index].clips.clear([block]) { Self.derivedID(of: $0.id, at: $1, taken: &taken) }
            copy.tracks[index].clips.insert(sorted: clips)
            pasted += clips.map(\.id)
        }
        self = copy
        return pasted
    }

    /// Splits each clip on each track that holds a frame strictly inside it. The frames go in
    /// descending order, so the IDs are those of single `split` calls in that order. A frame at a
    /// clip edge or in a gap does nothing. Returns the IDs of the right parts.
    @discardableResult
    public mutating func splitClips(at frames: [Frames], on tracks: [TrackID]) throws(SessionError) -> [ClipID] {
        var indices: [Int] = []
        for id in tracks { indices.append(try trackIndex(id)) }
        var taken = clipIDs
        var rights: [ClipID] = []
        for index in indices {
            for frame in frames.sorted(by: >) {
                guard let at = self.tracks[index].clips.index(holding: frame) else { continue }
                let clip = self.tracks[index].clips[at]
                guard clip.start < frame else { continue }
                let right = Self.derivedID(of: clip.id, at: frame, taken: &taken)
                self.tracks[index].clips.split(at: at, frame: frame, rightID: right)
                rights.append(right)
            }
        }
        return rights
    }

    /// Moves the clips by `offset` on their own tracks. They keep their IDs. The clips come out
    /// first, so two moved clips never cut each other. A clip that does not move is cut under the
    /// new ranges; its right part gets "<id>@<moved end>". A throw changes nothing.
    public mutating func nudge(_ clips: [ClipID], by offset: Frames) throws(SessionError) {
        // The offset is in -limit...limit before any sum, so a sum with a clip start cannot overflow.
        guard offset >= .zero - .limit, offset <= .limit else { throw .frameOutOfRange }
        let moving = Set(clips)
        var copy = self
        var taken = clipIDs
        var found = 0
        for index in tracks.indices {
            let moved = tracks[index].clips.filter { moving.contains($0.id) }.map { clip in
                var clip = clip
                clip.start = clip.start + offset
                return clip
            }
            guard !moved.isEmpty else { continue }
            found += moved.count
            // The start is in range before the end sum, and the length is not more than the limit.
            guard moved.allSatisfy({ $0.start.isInRange && $0.end.isInRange }) else { throw .frameOutOfRange }
            copy.tracks[index].clips.remove(ids: moving)
            copy.tracks[index].clips.clear(moved.map(\.range)) { Self.derivedID(of: $0.id, at: $1, taken: &taken) }
            copy.tracks[index].clips.insert(sorted: moved)
        }
        if found < moving.count, let missing = clips.first(where: { clip($0) == nil }) { throw .unknownClip(missing) }
        self = copy
    }
}
