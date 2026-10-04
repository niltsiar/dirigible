import Foundation

/// Ripple edits (decision 0037): an edit that closes or opens a gap, so the material after it
/// moves. Each edit works on a copy, so a throw changes nothing. The markers follow the ripple in
/// every scope (rule M). A track given twice ripples once.
extension Session {
    /// On each track of `tracks`, removes the frames in `range` (the edge clips are cut by the
    /// 0003 ID rule) and moves each clip at or after `range.upperBound` left by the length of the
    /// range. Each marker at or after the range end moves left by that length, and each marker in
    /// the range goes to the range start. An empty range or an empty track list changes nothing.
    public mutating func rippleDelete(_ range: Range<Frames>, on tracks: [TrackID]) throws(SessionError) {
        guard range.lowerBound.isInRange, range.upperBound.isInRange else { throw .frameOutOfRange }
        let indices = try trackIndices(tracks)
        guard !range.isEmpty, !indices.isEmpty else { return }
        let length = range.upperBound - range.lowerBound
        var copy = self
        var taken = clipIDs
        for index in indices {
            copy.tracks[index].clips.clear([range]) { Self.derivedID(of: $0.id, at: $1, taken: &taken) }
            copy.tracks[index].clips.shift(from: range.upperBound, by: .zero - length)
        }
        for marker in markers.values where marker.position > range.lowerBound {
            var moved = marker
            moved.position = max(range.lowerBound, marker.position - length)
            try copy.setMarker(moved)
        }
        self = copy
    }

    /// On each track of `tracks`, splits the clip that holds `frame` strictly inside it, then
    /// moves each clip at or after `frame` right by `length`: an insert of silence. Each marker at
    /// or after `frame` moves right by `length`. A clip end or a marker past `Frames.limit` throws
    /// `.frameOutOfRange`. A length of 0 or an empty track list changes nothing.
    public mutating func rippleInsert(_ length: Frames, at frame: Frames, on tracks: [TrackID]) throws(SessionError) {
        guard length.isInRange, frame.isInRange else { throw .frameOutOfRange }
        let indices = try trackIndices(tracks)
        guard length != .zero, !indices.isEmpty else { return }
        var copy = self
        var taken = clipIDs
        for index in indices {
            // The last clip has the largest end. It moves when it ends after `frame`. Both values
            // are in 0...limit, so the sum cannot overflow.
            if let last = copy.tracks[index].clips.last, last.end > frame, !(last.end + length).isInRange {
                throw .frameOutOfRange
            }
            if let at = copy.tracks[index].clips.index(holding: frame) {
                let clip = copy.tracks[index].clips[at]
                if clip.start < frame {
                    let right = Self.derivedID(of: clip.id, at: frame, taken: &taken)
                    copy.tracks[index].clips.split(at: at, frame: frame, rightID: right)
                }
            }
            copy.tracks[index].clips.shift(from: frame, by: length)
        }
        // `setMarker` refuses a position past `Frames.limit`; the throw discards the copy.
        for marker in markers.values where marker.position >= frame {
            var moved = marker
            moved.position = marker.position + length
            try copy.setMarker(moved)
        }
        self = copy
    }

    /// The index of each track of `ids`, in order, with each track once.
    private func trackIndices(_ ids: [TrackID]) throws(SessionError) -> [Int] {
        var indices: [Int] = []
        for id in ids {
            let index = try trackIndex(id)
            if !indices.contains(index) { indices.append(index) }
        }
        return indices
    }
}
