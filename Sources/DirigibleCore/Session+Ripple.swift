import Foundation

/// Ripple edits (decision 0037): an edit that closes or opens a gap, so the material after it
/// moves. Each edit works on a copy, so a throw changes nothing. The markers follow the ripple in
/// every scope (rule M). A track given twice ripples once.
extension Session {
    /// On each track of `tracks`, removes the frames in each range of `ranges`, in one edit. The
    /// overlapping and touching ranges merge first, and the cut goes from the last merged range to
    /// the first, so each range removes the frames that the caller gave. Each cut removes the
    /// frames of its range (the edge clips are cut by the 0003 ID rule) and moves each clip at or
    /// after the range end left by the length of the range. Each marker at or after the range end
    /// moves left by that length, and each marker in the range goes to the range start. An empty
    /// range is skipped. No range or an empty track list changes nothing.
    public mutating func rippleDelete(_ ranges: [Range<Frames>], on tracks: [TrackID]) throws(SessionError) {
        guard ranges.allSatisfy({ $0.lowerBound.isInRange && $0.upperBound.isInRange }) else {
            throw .frameOutOfRange
        }
        let lanes = try trackIndices(tracks)
        let merged = Self.merged(ranges)
        guard !merged.isEmpty, !lanes.isEmpty else { return }
        var copy = self
        var taken = clipIDs
        for range in merged.reversed() { try copy.rippleDelete(range, lanes: lanes, taken: &taken) }
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
    public mutating func rippleDelete(_ range: Range<Frames>, on tracks: [TrackID]) throws(SessionError) {
        try rippleDelete([range], on: tracks)
    }

    /// On each track of `tracks`, splits the clip that holds `frame` strictly inside it, then
    /// moves each clip at or after `frame` right by `length`: an insert of silence. Each marker at
    /// or after `frame` moves right by `length`. A clip end or a marker past `Frames.limit` throws
    /// `.frameOutOfRange`. A length of 0 or an empty track list changes nothing.
    public mutating func rippleInsert(_ length: Frames, at frame: Frames, on tracks: [TrackID]) throws(SessionError) {
        guard length.isInRange, frame.isInRange else { throw .frameOutOfRange }
        let lanes = try trackIndices(tracks)
        guard length != .zero, !lanes.isEmpty else { return }
        var copy = self
        var taken = clipIDs
        try copy.rippleInsert(length, at: frame, lanes: lanes, taken: &taken)
        self = copy
    }

    /// Moves one edge of the clip by `delta`, in the direction of the pointer, and ripples the
    /// span of `|delta|` at the old edge. The track of the clip always ripples, listed or not; the
    /// other `tracks` get a ripple delete of the span or an insert of silence there. The clip start
    /// stays: at the start edge, a positive delta removes the span from the clip head, and a
    /// negative delta adds media before it. The clip keeps its ID, the fade of the other edge stays
    /// and the trimmed fade yields (0035), and the crossfade at the trimmed edge goes from both
    /// clips (0036). Media outside the file throws `.clipOutsideFile`.
    public mutating func rippleTrim(_ id: ClipID, edge: Fades.Edge, by delta: Frames, on tracks: [TrackID])
        throws(SessionError)
    {
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
            crossfades: kept)
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
            try copy.rippleDelete(edge == .end ? (at - span)..<at : at..<(at + span), lanes: others, taken: &taken)
        } else {
            try copy.rippleInsert(span, at: at, lanes: others, taken: &taken)
        }
        self = copy
    }

    /// The ripple delete of `lanes` and the markers. The range is not empty and in range.
    private mutating func rippleDelete(_ range: Range<Frames>, lanes: [Int], taken: inout Set<ClipID>)
        throws(SessionError)
    {
        let length = range.upperBound - range.lowerBound
        for index in lanes {
            tracks[index].clips.clear([range]) { Self.derivedID(of: $0.id, at: $1, taken: &taken) }
            tracks[index].clips.shift(from: range.upperBound, by: .zero - length)
        }
        for marker in markers.values where marker.position > range.lowerBound {
            var moved = marker
            moved.position = max(range.lowerBound, marker.position - length)
            try setMarker(moved)
        }
    }

    /// The ripple insert of `lanes` and the markers. The length and the frame are in range.
    private mutating func rippleInsert(_ length: Frames, at frame: Frames, lanes: [Int], taken: inout Set<ClipID>)
        throws(SessionError)
    {
        for index in lanes {
            // The last clip has the largest end. It moves when it ends after `frame`. Both values
            // are in 0...limit, so the sum cannot overflow.
            if let last = tracks[index].clips.last, last.end > frame, !(last.end + length).isInRange {
                throw .frameOutOfRange
            }
            if let at = tracks[index].clips.index(cutting: frame) {
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
