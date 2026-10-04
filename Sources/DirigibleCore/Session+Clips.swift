import Foundation

extension Session {
    public func clip(_ id: ClipID) -> (clip: Clip, track: TrackID)? {
        for track in tracks {
            if let clip = track.clips.first(where: { $0.id == id }) { return (clip, track.id) }
        }
        return nil
    }

    /// Places the clip and overwrites the clips under it: they are trimmed, split, or removed.
    /// Placing a clip that is already there changes nothing.
    public mutating func place(_ clip: Clip, on track: TrackID) throws(SessionError) {
        let index = try trackIndex(track)
        if tracks[index].clips.contains(clip) { return }
        try Self.checkText(clip.id.rawValue)
        try check(clip, on: tracks[index])
        if self.clip(clip.id) != nil { throw .duplicateID(clip.id.rawValue) }
        var taken = clipIDs.union([clip.id])
        tracks[index].clips.overwrite(with: clip) { Self.derivedID(of: $0.id, at: $1, taken: &taken) }
    }

    /// Removes the frames in `range` from each track of `tracks` and leaves a gap. An unknown
    /// track throws before a change. The tracks clear in order, each with the IDs of the session
    /// at its turn, so an ID that an earlier track frees is free again.
    public mutating func clear(_ range: Range<Frames>, on tracks: [TrackID]) throws(SessionError) {
        for index in try trackIndices(tracks) {
            var taken = clipIDs
            self.tracks[index].clips.clear([range]) { Self.derivedID(of: $0.id, at: $1, taken: &taken) }
        }
    }

    /// Splits the clip at `frame` and returns the ID of the right part. The default ID is the
    /// first free one of "<id>@<frame>", "<id>@<frame>-2", "<id>@<frame>-3", and so on.
    @discardableResult
    public mutating func split(_ id: ClipID, at frame: Frames, rightID: ClipID? = nil) throws(SessionError) -> ClipID {
        let (track, index) = try position(of: id)
        let clip = tracks[track].clips[index]
        guard clip.start < frame, frame < clip.end else { throw .frameOutsideClip(id, frame) }
        var taken = clipIDs
        let right = rightID ?? Self.derivedID(of: id, at: frame, taken: &taken)
        try Self.checkText(right.rawValue)
        if self.clip(right) != nil { throw .duplicateID(right.rawValue) }
        tracks[track].clips.split(at: index, frame: frame, rightID: right)
        return right
    }

    /// Removes the clips and leaves gaps (decision 0038). A broken crossfade join loses its
    /// crossfade (decision 0036). An unknown ID throws, and a throw changes nothing.
    public mutating func removeClips(_ ids: [ClipID]) throws(SessionError) {
        // One pass over the lanes: a check of each ID with `clip(_:)` scans every lane per ID.
        let removed = Set(ids)
        let present = Set(tracks.lazy.flatMap(\.clips).map(\.id).filter(removed.contains))
        if let missing = ids.first(where: { !present.contains($0) }) { throw .unknownClip(missing) }
        for index in tracks.indices where tracks[index].clips.contains(where: { removed.contains($0.id) }) {
            tracks[index].clips.remove(ids: removed)
        }
    }

    /// Moves the clip to `start` on `track`, and overwrites the clips under it there.
    /// A move to the same track and start changes nothing, so it keeps the crossfades (decision 0036).
    public mutating func move(_ id: ClipID, to track: TrackID, start: Frames) throws(SessionError) {
        let (source, index) = try position(of: id)
        if tracks[source].id == track, tracks[source].clips[index].start == start { return }
        var moved = tracks[source].clips[index]
        moved.start = start
        var copy = self
        copy.tracks[source].clips.remove(at: index)
        try copy.place(moved, on: track)
        self = copy
    }

    /// Gives the clip a new timeline range. The file offset follows the start. The clip does not
    /// grow into a neighbor. The fade of the edge that does not move stays; the other fade yields
    /// (decision 0035). When both edges move, the fade-in stays. The crossfade of an edge that does
    /// not move stays, and the fades yield to its half (decision 0036).
    public mutating func trim(_ id: ClipID, to range: Range<Frames>) throws(SessionError) {
        let (track, index) = try position(of: id)
        let clip = tracks[track].clips[index]
        guard range.lowerBound.isInRange else { throw .frameOutOfRange }
        let offset = clip.offset + (range.lowerBound - clip.start)
        guard offset >= .zero else { throw .clipOutsideFile(id) }
        let kept: Fades.Edge = range.lowerBound != clip.start && range.upperBound == clip.end ? .end : .start
        var trimmed = Clip(
            id: id, file: clip.file, start: range.lowerBound, offset: offset,
            length: range.upperBound - range.lowerBound, gain: clip.gain,
            crossfades: .kept(edgesOf: clip, in: range))
        trimmed.fades = trimmed.fitting(clip.fades, keeping: kept)
        try check(trimmed, on: tracks[track])
        if let neighbor = tracks[track].clips.clips(overlapping: trimmed.range).first(where: { $0.id != id }) {
            throw .overlap(id, neighbor.id)
        }
        tracks[track].clips.replace(at: index, with: trimmed)
    }

    public mutating func setGain(_ gain: Gain, clip id: ClipID) throws(SessionError) {
        let (track, index) = try position(of: id)
        var clip = tracks[track].clips[index]
        clip.gain = gain
        tracks[track].clips.replace(at: index, with: clip)
    }

    /// Sets the gain of each clip in one pass over the lanes. An unknown ID throws `.unknownClip`.
    /// A throw changes nothing.
    public mutating func setGains(_ gains: [ClipID: Gain]) throws(SessionError) {
        var lanes = tracks
        var found = 0
        for track in lanes.indices {
            for index in lanes[track].clips.indices {
                guard let new = gains[lanes[track].clips[index].id] else { continue }
                var clip = lanes[track].clips[index]
                clip.gain = new
                lanes[track].clips.replace(at: index, with: clip)
                found += 1
            }
        }
        if found < gains.count, let missing = gains.keys.sorted().first(where: { clip($0) == nil }) {
            throw .unknownClip(missing)
        }
        tracks = lanes
    }

    /// Sets the fades of each clip in one pass over the lanes (decision 0035). Each clip passes
    /// `check`. An unknown ID throws `.unknownClip`. A throw changes nothing.
    public mutating func setFades(_ fades: [ClipID: Fades]) throws(SessionError) {
        var lanes = tracks
        var found = 0
        // The scan stops at the last clip of the map, so a small map on an early track is quick.
        for track in lanes.indices where found < fades.count {
            for (index, old) in lanes[track].clips.enumerated() {
                guard let new = fades[old.id] else { continue }
                var clip = old
                clip.fades = new
                try check(clip, on: lanes[track])
                lanes[track].clips.replace(at: index, with: clip)
                found += 1
                if found == fades.count { break }
            }
        }
        if found < fades.count, let missing = fades.keys.sorted().first(where: { clip($0) == nil }) {
            throw .unknownClip(missing)
        }
        tracks = lanes
    }

    /// Sets the clips of a track from a file: checks each clip and refuses two clips that overlap.
    mutating func setClips(_ clips: [Clip], on track: TrackID) throws(SessionError) {
        let index = try trackIndex(track)
        var taken = clipIDs
        for clip in clips {
            try check(clip, on: tracks[index])
            guard taken.insert(clip.id).inserted else { throw .duplicateID(clip.id.rawValue) }
        }
        tracks[index].clips = try ClipLane(validating: clips)
    }

    /// Checks the clip against its file and its track. The comparisons cannot overflow:
    /// the start is in `0...Frames.limit`, and the length is not more than the file length. Each
    /// crossfade half has media handle in the file (decision 0036). `ClipLane` checks the pairing.
    func check(_ clip: Clip, on track: Track) throws(SessionError) {
        guard clip.start.isInRange, clip.offset >= .zero else { throw .frameOutOfRange }
        guard let file = files[clip.file] else { throw .unknownFile(clip.file) }
        guard file.layout == track.layout else { throw .layoutMismatch(track.id, .file(file.id)) }
        guard clip.length > .zero, clip.length <= file.length - clip.offset else { throw .clipOutsideFile(clip.id) }
        let (before, after) = (clip.crossfades.start.half, clip.crossfades.end.half)
        guard (before == .zero || clip.fades.fadeIn == .zero) && (after == .zero || clip.fades.fadeOut == .zero) else {
            throw .fadeAtCrossfade(clip.id)
        }
        guard before <= clip.offset else { throw .crossfadeOutsideFile(clip.id, needed: before) }
        guard clip.offset + clip.length + after <= file.length else {
            throw .crossfadeOutsideFile(clip.id, needed: after)
        }
        guard clip.reach(.start) + clip.reach(.end) <= clip.length else {
            throw .fadeOutsideClip(clip.id, length: clip.length)
        }
    }

    func position(of id: ClipID) throws(SessionError) -> (track: Int, index: Int) {
        for (track, lane) in tracks.map(\.clips).enumerated() {
            if let index = lane.firstIndex(where: { $0.id == id }) { return (track, index) }
        }
        throw .unknownClip(id)
    }

    var clipIDs: Set<ClipID> {
        Set(tracks.flatMap { $0.clips.map(\.id) })
    }

    /// The first free ID of "<id>@<frame>", "<id>@<frame>-2", and so on. It goes into `taken`, so
    /// the next call of one edit does not take it again.
    static func derivedID(of id: ClipID, at frame: Frames, taken: inout Set<ClipID>) -> ClipID {
        let base = "\(id.rawValue)@\(frame.count)"
        var candidate = ClipID(base)
        var number = 2
        while taken.contains(candidate) {
            candidate = ClipID("\(base)-\(number)")
            number += 1
        }
        taken.insert(candidate)
        return candidate
    }
}
