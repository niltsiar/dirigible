import Foundation

/// Ripple edits (decision 0037): an edit that closes or opens a gap, so the material after it
/// moves. Each edit works on a copy, so a throw changes nothing. The markers follow the ripple in
/// every scope (rule M). A track given twice ripples once.
extension Session {
    /// On each track of `tracks`, removes the frames in each range of `ranges`, in one edit. The
    /// overlapping and touching ranges merge first, so each range removes the frames that the
    /// caller gave. On each track of `cuttingTracks(tracks, naming:)` the cut removes the frames of
    /// each range (the edge clips are cut by the 0003 ID rule) and moves each clip left by the length
    /// of the ranges before it. On a follow track that `naming` does not hold, no clip is cut: each
    /// start maps as a marker does, and an overlap throws `.followOverlap` (decision 0073). Each
    /// marker moves left by the removed frames before it, so a marker in a range goes to the range
    /// start. An empty range is skipped. No range or an empty track list changes nothing; else a
    /// scope where no track cuts throws `.noRippleTrack`.
    public mutating func rippleDelete(_ ranges: [Range<Frames>], on tracks: [TrackID], naming: [TrackID] = [])
        throws(SessionError)
    {
        guard ranges.allSatisfy({ $0.lowerBound.isInRange && $0.upperBound.isInRange }) else {
            throw .frameOutOfRange
        }
        let lanes = try trackIndices(tracks)
        let merged = Self.merged(ranges)
        guard !merged.isEmpty, !lanes.isEmpty else { return }
        guard !cuttingTracks(tracks, naming: naming).isEmpty else { throw .noRippleTrack }
        var copy = self
        var taken = clipIDs
        try copy.rippleDelete(merged, lanes: lanes, naming: naming, taken: &taken)
        self = copy
    }

    /// The ranges that the array form of `rippleDelete` cuts: no empty range, in order, and each
    /// overlapping or touching pair as one range.
    static func merged(_ ranges: [Range<Frames>]) -> [Range<Frames>] {
        var merged: [Range<Frames>] = []
        for range in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// On each track of `tracks`, removes the frames in `range`. It calls the array form with one
    /// range.
    public mutating func rippleDelete(_ range: Range<Frames>, on tracks: [TrackID], naming: [TrackID] = [])
        throws(SessionError)
    {
        try rippleDelete([range], on: tracks, naming: naming)
    }

    /// The tracks of `tracks` that a ripple cuts: each track that does not follow, and each track
    /// that the edit names (decision 0073). The ripple lanes, the `.noRippleTrack` refusal, and the
    /// excerpt of a Cut in the window read this rule.
    public func cuttingTracks(_ tracks: [TrackID], naming: [TrackID]) -> [TrackID] {
        tracks.filter { naming.contains($0) || track($0)?.isFollowTrack != true }
    }

    /// On each track of `cuttingTracks(tracks, naming:)`, splits the clip that holds `frame` strictly
    /// inside it, then moves each clip at or after `frame` right by `length`: an insert of silence.
    /// On a follow track that `naming` does not hold, no clip splits (decision 0073). Each marker at
    /// or after `frame` moves right by `length`. A clip end or a marker past `Frames.limit` throws
    /// `.frameOutOfRange`. A length of 0 or an empty track list changes nothing; else a scope where
    /// no track cuts throws `.noRippleTrack`.
    public mutating func rippleInsert(_ length: Frames, at frame: Frames, on tracks: [TrackID], naming: [TrackID] = [])
        throws(SessionError)
    {
        guard length.isInRange, frame.isInRange else { throw .frameOutOfRange }
        let lanes = try trackIndices(tracks)
        guard length != .zero, !lanes.isEmpty else { return }
        guard !cuttingTracks(tracks, naming: naming).isEmpty else { throw .noRippleTrack }
        var copy = self
        var taken = clipIDs
        try copy.rippleInsert(length, at: frame, lanes: lanes, naming: naming, taken: &taken)
        self = copy
    }

    /// Moves one edge of the clip by `delta`, in the direction of the pointer, and ripples the
    /// span of `|delta|` at the old edge. The track of the clip always ripples, listed or not; the
    /// other `tracks` get a ripple delete of the span or an insert of silence there. The clip start
    /// stays: at the start edge, a positive delta removes the span from the clip head, and a
    /// negative delta adds media before it. The clip keeps its ID, the fade of the other edge stays
    /// and the trimmed fade yields (0035), and the crossfade at the trimmed edge goes from both
    /// clips (0036). Media outside the file throws `.clipOutsideFile`. The other tracks take the
    /// follow rule of `rippleDelete` and `rippleInsert` with `naming`.
    public mutating func rippleTrim(
        _ id: ClipID, edge: Fades.Edge, by delta: Frames, on tracks: [TrackID], naming: [TrackID] = []
    ) throws(SessionError) {
        guard delta >= .zero - .limit, delta <= .limit else { throw .frameOutOfRange }
        let (own, index) = try position(of: id)
        let others = try trackIndices(tracks).filter { $0 != own }
        guard delta != .zero else { return }
        let clip = self.tracks[own].clips[index]
        // The signed change of the clip length, which is also the move of the later clips.
        let change = edge == .end ? delta : .zero - delta
        let offset = edge == .start ? clip.offset + delta : clip.offset
        let length = clip.length + change
        guard offset >= .zero, length > .zero else { throw .clipOutsideFile(id) }
        let kept = Crossfades(
            valid: edge == .start ? .zero : clip.crossfades.start, end: edge == .end ? .zero : clip.crossfades.end)
        var trimmed = Clip(
            id: id, file: clip.file, start: clip.start, offset: offset, length: length, gain: clip.gain,
            crossfades: kept, envelope: clip.envelope)
        trimmed.fades = trimmed.fitting(clip.fades, keeping: edge.other)
        try check(trimmed, on: self.tracks[own])
        // Both values are in 0...limit, so the sum cannot overflow.
        if change > .zero, let last = self.tracks[own].clips.last, !(last.end + change).isInRange {
            throw .frameOutOfRange
        }
        let at = edge == .end ? clip.end : clip.start
        let span = Frames(abs(delta.count))
        var copy = self
        var taken = clipIDs
        copy.tracks[own].clips.ripple(at: index, with: trimmed)
        if change < .zero {
            try copy.rippleDelete(
                [edge == .end ? (at - span)..<at : at..<(at + span)], lanes: others, naming: naming, taken: &taken)
        } else {
            try copy.rippleInsert(span, at: at, lanes: others, naming: naming, taken: &taken)
        }
        self = copy
    }

    /// The ripple delete of `lanes` and the markers, in one pass. The ranges are in range and
    /// merged (`merged`). A lane that `cuttingTracks` leaves out follows.
    mutating func rippleDelete(
        _ ranges: [Range<Frames>], lanes: [Int], naming: [TrackID], taken: inout Set<ClipID>
    ) throws(SessionError) {
        let cutting = Set(cuttingTracks(lanes.map { tracks[$0].id }, naming: naming))
        for index in lanes {
            if cutting.contains(tracks[index].id) {
                tracks[index].clips.rippleDelete(ranges) { Self.derivedID(of: $0.id, at: $1, taken: &taken) }
            } else {
                try tracks[index].clips.follow(deleting: ranges)
            }
        }
        for marker in markers.values {
            var moved = marker
            moved.position = marker.position.afterRippleDelete(of: ranges)
            if moved.position != marker.position { try setMarker(moved) }
        }
    }

    /// The ripple insert of `lanes` and the markers. The length and the frame are in range. A lane
    /// that `cuttingTracks` leaves out follows: no clip splits.
    mutating func rippleInsert(
        _ length: Frames, at frame: Frames, lanes: [Int], naming: [TrackID], taken: inout Set<ClipID>
    ) throws(SessionError) {
        let cutting = Set(cuttingTracks(lanes.map { tracks[$0].id }, naming: naming))
        for index in lanes {
            let cuts = cutting.contains(tracks[index].id)
            // The last clip has the largest end. It moves when it ends after `frame`, or on a follow
            // lane when it starts at or after `frame`. Both values are in 0...limit, so the sum cannot
            // overflow.
            if let last = tracks[index].clips.last, cuts ? last.end > frame : last.start >= frame,
                !(last.end + length).isInRange
            {
                throw .frameOutOfRange
            }
            if cuts, let at = tracks[index].clips.index(cutting: frame) {
                let right = Self.derivedID(of: tracks[index].clips[at].id, at: frame, taken: &taken)
                tracks[index].clips.split(at: at, frame: frame, rightID: right)
            }
            tracks[index].clips.shift(from: frame, by: length)
        }
        // `setMarker` refuses a position past `Frames.limit`; the caller discards its copy.
        for marker in markers.values where marker.position >= frame {
            var moved = marker
            moved.position = marker.position + length
            try setMarker(moved)
        }
    }

    /// The index of each track of `ids`, in order, with each track once.
    func trackIndices(_ ids: [TrackID]) throws(SessionError) -> [Int] {
        var indices: [Int] = []
        for id in ids {
            let index = try trackIndex(id)
            if !indices.contains(index) { indices.append(index) }
        }
        return indices
    }
}

extension Frames {
    /// This frame after a ripple delete of `ranges` (Rule M, decision 0037): a frame at or after the
    /// end of a range moves left by its length, a frame inside a range goes to its start, and a
    /// frame at the start stays. `ranges` are sorted and do not overlap. The markers of the session
    /// and the playhead of the window both map through this function.
    public func afterRippleDelete(of ranges: [Range<Frames>]) -> Frames {
        var removed = Frames.zero
        for range in ranges {
            if self >= range.upperBound {
                removed = removed + (range.upperBound - range.lowerBound)
            } else if self > range.lowerBound {
                return range.lowerBound - removed
            } else {
                break
            }
        }
        return self - removed
    }
}
