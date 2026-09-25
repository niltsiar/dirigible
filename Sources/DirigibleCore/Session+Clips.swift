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

    /// Removes the frames in `range` from the track and leaves a gap.
    public mutating func clear(_ range: Range<Frames>, on track: TrackID) throws(SessionError) {
        let index = try trackIndex(track)
        var taken = clipIDs
        tracks[index].clips.clear([range]) { Self.derivedID(of: $0.id, at: $1, taken: &taken) }
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

    /// Moves the clip to `start` on `track`, and overwrites the clips under it there.
    public mutating func move(_ id: ClipID, to track: TrackID, start: Frames) throws(SessionError) {
        let (source, index) = try position(of: id)
        var moved = tracks[source].clips[index]
        moved.start = start
        var copy = self
        copy.tracks[source].clips.remove(at: index)
        try copy.place(moved, on: track)
        self = copy
    }

    /// Gives the clip a new timeline range. The file offset follows the start. The clip does not
    /// grow into a neighbor.
    public mutating func trim(_ id: ClipID, to range: Range<Frames>) throws(SessionError) {
        let (track, index) = try position(of: id)
        let clip = tracks[track].clips[index]
        guard range.lowerBound.isInRange else { throw .frameOutOfRange }
        let offset = clip.offset + (range.lowerBound - clip.start)
        guard offset >= .zero else { throw .clipOutsideFile(id) }
        let trimmed = Clip(
            id: id, file: clip.file, start: range.lowerBound, offset: offset,
            length: range.upperBound - range.lowerBound, gain: clip.gain)
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
    /// the start is in `0...Frames.limit`, and the length is not more than the file length.
    func check(_ clip: Clip, on track: Track) throws(SessionError) {
        guard clip.start.isInRange, clip.offset >= .zero else { throw .frameOutOfRange }
        guard let file = files[clip.file] else { throw .unknownFile(clip.file) }
        guard file.layout == track.layout else { throw .layoutMismatch(track.id, .file(file.id)) }
        guard clip.length > .zero, clip.length <= file.length - clip.offset else { throw .clipOutsideFile(clip.id) }
    }

    private func position(of id: ClipID) throws(SessionError) -> (track: Int, index: Int) {
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
