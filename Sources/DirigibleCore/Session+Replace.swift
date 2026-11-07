import Foundation

/// Replace and Paste to Fill Selection (decision 0053).
extension Session {
    /// The most new clips that one fill makes: 0.5 s of room tone fills 500 s.
    public static let fillClipLimit = 1_000

    /// On every track, removes `range` and closes the gap, then opens the length of `excerpt` at
    /// the range start, and pastes `excerpt` there on `tracks`, in one edit. So each later clip on
    /// every track moves by the excerpt length minus the range length. A marker in the range or at
    /// its start ends at the range start; a marker at or after the range end moves with the later
    /// clips (Rule M Replace clause, decision 0037). The paste targets `tracks` are named, so a
    /// follow track among them is cut; on another follow track each clip start maps as a marker
    /// does, and an overlap throws `.followOverlap` (decision 0073). An excerpt of length 0 throws
    /// `.emptyExcerpt`. Returns the pasted IDs. A throw changes nothing.
    @discardableResult
    public mutating func replace(_ range: Range<Frames>, with excerpt: Excerpt, on tracks: [TrackID])
        throws(SessionError) -> [ClipID]
    {
        guard excerpt.length > .zero else { throw .emptyExcerpt }
        guard range.lowerBound.isInRange, range.upperBound.isInRange, excerpt.length.isInRange else {
            throw .frameOutOfRange
        }
        let inside = markers.values.filter { range.lowerBound <= $0.position && $0.position < range.upperBound }
        var copy = self
        if !self.tracks.isEmpty {
            let cutting = Set(cuttingTracks(self.tracks.map(\.id), naming: tracks))
            let lanes = self.tracks.indices.filter { cutting.contains(self.tracks[$0].id) }
            var taken = clipIDs
            if !range.isEmpty { try copy.rippleDelete([range], lanes: lanes, naming: tracks, taken: &taken) }
            // The delete cuts each clip of a cutting lane at the range start, so the insert derives
            // no ID from `taken`.
            try copy.rippleInsert(excerpt.length, at: range.lowerBound, lanes: lanes, naming: tracks, taken: &taken)
            // A follow lane maps once: after the delete, a clip from inside the range and a clip from
            // the range end both start at the range start, and the insert cannot tell them apart.
            for index in self.tracks.indices where !cutting.contains(self.tracks[index].id) {
                try copy.tracks[index].clips.follow { $0.afterReplace(of: range, with: excerpt.length) }
            }
        }
        for marker in inside {
            var kept = marker
            kept.position = range.lowerBound
            try copy.setMarker(kept)
        }
        let pasted = try copy.paste(excerpt, at: range.lowerBound, on: tracks)
        self = copy
        return pasted
    }

    /// Pastes `excerpt` again and again from the start of `range` on `tracks`, with butt joins:
    /// a clip keeps no crossfade at a copy edge, so no copy pairs with the next one. It cuts the
    /// last copy at the range end. The range clears as one block, so the gaps of a clip set stay
    /// silent, and no clip moves. It is one `paste` of one tiled excerpt, so each
    /// clip gets its check, its envelope, and a derived ID, and the words of another package come
    /// once. An excerpt of length 0 throws `.emptyExcerpt`; more than `fillClipLimit` new clips
    /// throws `.fillTooManyClips` before any copy. Returns the pasted IDs. A throw changes nothing.
    @discardableResult
    public mutating func fill(_ range: Range<Frames>, with excerpt: Excerpt, on tracks: [TrackID])
        throws(SessionError) -> [ClipID]
    {
        guard range.lowerBound.isInRange, range.upperBound.isInRange else { throw .frameOutOfRange }
        guard excerpt.length > .zero else { throw .emptyExcerpt }
        let span = (range.upperBound - range.lowerBound).count
        let period = excerpt.length.count
        // Each clip that starts before the range end places once for each copy, so the count
        // needs no loop over the copies.
        let needed = excerpt.lanes.reduce(0) { sum, lane in
            lane.clips.reduce(sum) { sum, clip in
                clip.start.count < span ? sum + (span - clip.start.count - 1) / period + 1 : sum
            }
        }
        guard needed <= Self.fillClipLimit else { throw .fillTooManyClips(needed: needed) }
        let end = Frames(span)
        let lanes = excerpt.lanes.map { lane in
            var tiled = lane
            // A lane with a clip places one for each copy, so `needed` bounds this loop.
            guard !lane.clips.isEmpty else { return tiled }
            let clips = lane.clips.map { clip in
                var edged = clip
                edged.crossfades = Crossfades(
                    valid: clip.start == .zero ? .zero : clip.crossfades.start,
                    end: clip.end == excerpt.length ? .zero : clip.crossfades.end)
                return edged
            }
            tiled.clips = stride(from: 0, to: span, by: period).flatMap { copy in
                clips.compactMap { clip -> Clip? in
                    var placed = clip
                    placed.start = Frames(copy) + clip.start
                    guard placed.start < end else { return nil }
                    return placed.end > end ? placed.cut(to: placed.start..<end, id: clip.id) : placed
                }
            }
            return tiled
        }
        var tiled = Excerpt(
            kind: .range, length: end, lanes: lanes, sampleRate: excerpt.sampleRate, pool: excerpt.files,
            transcripts: excerpt.transcripts)
        tiled.pastesWords = excerpt.pastesWords
        return try paste(tiled, at: range.lowerBound, on: tracks)
    }
}
