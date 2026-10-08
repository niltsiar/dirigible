import Foundation

/// A copy of timeline material: the parts of the clips in one range on some tracks, or the whole
/// clips of a clip set. Only `Session.excerpt` makes one, so each lane is sorted, has no overlap,
/// and has clip starts relative to the excerpt start. It carries the pool record of each file that
/// its clips name and the rate of its frames, so a paste can tell a file of another pool (decision
/// 0042).
public struct Excerpt: Hashable, Sendable {
    /// The clear rule of a paste.
    public enum Kind: Hashable, Sendable {
        /// The paste clears the whole block on each target track (decision 0018).
        case range
        /// The paste clears only the frames under each pasted clip (decision 0038).
        case clips
    }

    public struct Lane: Hashable, Sendable {
        public let source: TrackID
        /// The name and the layout of the source track, for a paste that makes new tracks.
        public let name: String
        public let layout: ChannelLayout
        public internal(set) var clips: [Clip]
    }

    public let kind: Kind
    public let length: Frames
    public internal(set) var lanes: [Lane]
    /// The session rate of the frames.
    public let sampleRate: Int
    /// The pool record of each file that a clip names, and no other.
    public internal(set) var files: [FileID: AudioFile]

    init(kind: Kind, length: Frames, lanes: [Lane], sampleRate: Int, pool: [FileID: AudioFile]) {
        self.kind = kind
        self.length = length
        self.lanes = lanes
        self.sampleRate = sampleRate
        let named = Set(lanes.flatMap { $0.clips.map(\.file) })
        files = pool.filter { named.contains($0.key) }
    }

    /// The excerpt with each clip file replaced by the ID of its record in `records`, and those
    /// records as `files` (decision 0042). Every other clip field stays. A clip file with no
    /// record throws `.unknownFile`.
    public func mapped(to records: [FileID: AudioFile]) throws(SessionError) -> Excerpt {
        var mapped = self
        var used: [FileID: AudioFile] = [:]
        for lane in mapped.lanes.indices {
            for index in mapped.lanes[lane].clips.indices {
                let file = mapped.lanes[lane].clips[index].file
                guard let record = records[file] else { throw .unknownFile(file) }
                mapped.lanes[lane].clips[index].file = record.id
                used[record.id] = record
            }
        }
        mapped.files = used
        return mapped
    }
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
            let track = self.tracks[try trackIndex(id)]
            let clips = track.clips.clips(overlapping: range).map { clip in
                var part = clip.cut(
                    to: max(clip.start, range.lowerBound)..<min(clip.end, range.upperBound), id: clip.id)
                part.start = part.start - range.lowerBound
                return part
            }
            lanes.append(Excerpt.Lane(source: id, name: track.name, layout: track.layout, clips: clips))
        }
        return Excerpt(
            kind: .range, length: range.upperBound - range.lowerBound, lanes: lanes, sampleRate: sampleRate, pool: files
        )
    }

    /// The whole clips of a clip set (decision 0038). The starts are relative to the first start,
    /// and the length goes to the last end. One lane for each track from the first to the last
    /// track with a listed clip, in session order: a track between them gives an empty lane. An
    /// unknown ID throws. An empty list gives no lane and length 0.
    public func excerpt(of clips: [ClipID]) throws(SessionError) -> Excerpt {
        // One pass over the lanes: a check of each ID with `clip(_:)` scans every lane per ID.
        let wanted = Set(clips)
        let picked = tracks.map { $0.clips.filter { wanted.contains($0.id) } }
        let present = Set(picked.joined().map(\.id))
        if let missing = clips.first(where: { !present.contains($0) }) { throw .unknownClip(missing) }
        guard let first = picked.firstIndex(where: { !$0.isEmpty }),
            let last = picked.lastIndex(where: { !$0.isEmpty }),
            let start = picked.compactMap(\.first?.start).min(), let end = picked.compactMap(\.last?.end).max()
        else { return Excerpt(kind: .clips, length: .zero, lanes: [], sampleRate: sampleRate, pool: [:]) }
        let lanes = (first...last).map { index in
            Excerpt.Lane(
                source: tracks[index].id, name: tracks[index].name, layout: tracks[index].layout,
                clips: picked[index].map { clip in
                    var clip = clip
                    clip.start = clip.start - start
                    return clip
                })
        }
        return Excerpt(kind: .clips, length: end - start, lanes: lanes, sampleRate: sampleRate, pool: files)
    }

    /// Lane i goes to `tracks[i]`. A range excerpt clears the whole block `start..<start + length`
    /// on the track, also under a gap of the excerpt; a clip set excerpt clears only the frames
    /// under each pasted clip. Then the paste adds the lane clips. A pasted clip gets
    /// the first free ID of "<source id>@<start>"; the right part of a cut clip gets
    /// "<id>@<end of the cleared range>": the block end, or the end of the pasted clip. Returns
    /// the pasted IDs, lane by lane. A clip whose file record differs from the record of its ID here
    /// throws `.foreignFile` (decision 0042). A throw changes nothing.
    @discardableResult
    public mutating func paste(_ excerpt: Excerpt, at start: Frames, on tracks: [TrackID]) throws(SessionError)
        -> [ClipID]
    {
        // The frames of the excerpt are at its own rate (decision 0042).
        guard excerpt.sampleRate == sampleRate else { throw .otherSampleRate(excerpt.sampleRate) }
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
                // A record of one ID never changes in a session, so a different record is a file of
                // another pool that only shares the ID (decision 0042).
                if let record = excerpt.files[clip.file], let present = files[clip.file], present != record {
                    throw .foreignFile(clip.file)
                }
                let placed = Clip(
                    id: Self.derivedID(of: clip.id, at: start + clip.start, taken: &taken), file: clip.file,
                    start: start + clip.start, offset: clip.offset, length: clip.length, gain: clip.gain,
                    fades: clip.fades, crossfades: clip.crossfades)
                try check(placed, on: self.tracks[index])
                clips.append(placed)
            }
            let cleared = excerpt.kind == .range ? [block] : clips.map(\.range)
            copy.tracks[index].clips.clear(cleared) { Self.derivedID(of: $0.id, at: $1, taken: &taken) }
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

    /// Moves the clips by `offset` and by `lanes` tracks (decision 0038). They keep their IDs. Every
    /// moved clip comes out of every lane first, so two moved clips never cut each other. A clip that
    /// does not move is cut under the new ranges; its right part gets "<id>@<moved end>". Only an
    /// offset of 0 with a lane offset of 0 changes nothing. A throw changes nothing.
    public mutating func nudge(_ clips: [ClipID], by offset: Frames, lanes: Int = 0) throws(SessionError) {
        // The offset is in -limit...limit before any sum, so a sum with a clip start cannot overflow.
        guard offset >= .zero - .limit, offset <= .limit else { throw .frameOutOfRange }
        // No move changes nothing, so it keeps the crossfades (decision 0036).
        if offset == .zero && lanes == 0 {
            if let missing = clips.first(where: { clip($0) == nil }) { throw .unknownClip(missing) }
            return
        }
        let moving = Set(clips)
        var moves: [(source: Int, clips: [Clip])] = []
        var found = 0
        for index in tracks.indices {
            let moved = tracks[index].clips.filter { moving.contains($0.id) }.map { clip in
                var clip = clip
                clip.start = clip.start + offset
                return clip
            }
            guard let first = moved.first else { continue }
            found += moved.count
            // The magnitude check comes first, so the sum cannot overflow.
            guard lanes.magnitude < UInt(tracks.count), tracks.indices.contains(index + lanes) else {
                throw .laneOutOfRange(first.id)
            }
            // The start is in range before the end sum, and the length is not more than the limit.
            guard moved.allSatisfy({ $0.start.isInRange && $0.end.isInRange }) else { throw .frameOutOfRange }
            if lanes != 0 { for clip in moved { try check(clip, on: tracks[index + lanes]) } }
            moves.append((index, moved))
        }
        if found < moving.count, let missing = clips.first(where: { clip($0) == nil }) { throw .unknownClip(missing) }
        var copy = self
        var taken = clipIDs
        for (source, _) in moves { copy.tracks[source].clips.remove(ids: moving) }
        // One lane offset for all clips, so each target lane takes the sorted clips of one lane.
        for (source, moved) in moves {
            copy.tracks[source + lanes].clips.clear(moved.map(\.range)) {
                Self.derivedID(of: $0.id, at: $1, taken: &taken)
            }
            copy.tracks[source + lanes].clips.insert(sorted: moved)
        }
        self = copy
    }
}
