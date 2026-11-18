import Foundation

extension Session {
    /// The search distance on each side of the clip when a sync names none: 1800 s (decision 0076).
    public var defaultSyncWithin: Frames { Frames(1800 * sampleRate) }

    /// The longest search span of a sync after its cut to frame 0 and the session end:
    /// (2^24 - 120000) x floor(rate / 2000) frames, so the coarse FFT of the span and of one 60 s
    /// excerpt fits 2^24 samples (decision 0076, **Search span**).
    public var syncSpanCap: Frames { Frames(((1 << 24) - 120_000) * max(1, sampleRate / 2000)) }

    /// The `within` that a sync of `clip` uses (decision 0076, **Search span**). Nil gives
    /// `defaultSyncWithin`, clamped to the largest `within` whose cut span fits `syncSpanCap`.
    /// A `within` under 0 or over `Frames.limit` throws `.frameOutOfRange`, and a larger one than
    /// that largest `within` throws `.syncSpanTooLong(maxWithin:)`. A clip longer than the cap
    /// throws `.syncSpanTooLong(maxWithin: 0)` for every `within`.
    public func syncWithin(_ clip: ClipID, within: Frames? = nil) throws(SessionError) -> Frames {
        guard let (found, _) = self.clip(clip) else { throw .unknownClip(clip) }
        let largest = try largestSyncWithin(found)
        guard let within else { return min(defaultSyncWithin, largest ?? defaultSyncWithin) }
        guard within >= .zero, within <= .limit else { throw .frameOutOfRange }
        if let largest, within > largest { throw .syncSpanTooLong(maxWithin: largest) }
        return within
    }

    /// The reference span of a sync of `clip` to `track`: the clip range widened by the `within`
    /// of `syncWithin` on each side, cut to frame 0 and the session end. It throws the errors of
    /// `syncWithin`, `.unknownTrack`, `.syncSameTrack` for the track of the clip, and
    /// `.noReferenceAudio` when no clip of `track` overlaps the span.
    public func syncSpan(_ clip: ClipID, to track: TrackID, within: Frames? = nil) throws(SessionError)
        -> Range<Frames>
    {
        guard let (found, home) = self.clip(clip) else { throw .unknownClip(clip) }
        guard let reference = self.track(track) else { throw .unknownTrack(track) }
        guard track != home else { throw .syncSameTrack }
        let span = span(of: found, within: try syncWithin(clip, within: within))
        guard !reference.clips.clips(overlapping: span).isEmpty else { throw .noReferenceAudio }
        return span
    }

    /// The reference that a sync of `clip` takes by default: the first other track with an app
    /// route that holds a clip in the default span, else the first other track that holds a clip
    /// there, else nil (decision 0076).
    public func defaultSyncReference(for clip: ClipID) -> TrackID? {
        guard let (found, home) = self.clip(clip), let within = try? syncWithin(clip) else { return nil }
        let span = span(of: found, within: within)
        let candidates = tracks.filter { $0.id != home && !$0.clips.clips(overlapping: span).isEmpty }
        let call = candidates.first {
            if case .app = $0.route { true } else { false }
        }
        return (call ?? candidates.first)?.id
    }

    /// Moves `clip` by `lag` with the rules of `nudge`: it keeps its ID, and the clips under its
    /// new range on its track are cut. A new start under frame 0 first cuts the head of the clip
    /// to frame 0; the result is the frames cut. A new end at or under frame 0 throws
    /// `.frameOutOfRange`. A throw changes nothing.
    public mutating func sync(_ clip: ClipID, by lag: Frames) throws(SessionError) -> Frames {
        guard let (found, _) = self.clip(clip) else { throw .unknownClip(clip) }
        guard lag >= .zero - .limit, lag <= .limit else { throw .frameOutOfRange }
        guard found.end + lag > .zero else { throw .frameOutOfRange }
        let cut = max(.zero, .zero - (found.start + lag))
        var copy = self
        if cut > .zero { try copy.trim(clip, to: found.start + cut..<found.end) }
        try copy.nudge([clip], by: lag)
        self = copy
        return cut
    }

    /// The session that a sync reads: mute and solo off, and only `clip` on its track.
    public func syncSource(_ clip: ClipID) -> Session {
        var copy = ignoringMuteAndSolo
        for index in copy.tracks.indices where copy.tracks[index].clips.contains(where: { $0.id == clip }) {
            copy.tracks[index].clips.remove(ids: Set(copy.tracks[index].clips.map(\.id)).subtracting([clip]))
        }
        return copy
    }

    /// The clip range widened by `within` on each side, cut to frame 0 and the session end.
    private func span(of clip: Clip, within: Frames) -> Range<Frames> {
        max(.zero, clip.start - within)..<min(end, clip.end + within)
    }

    /// The largest `within` whose span around `clip` fits `syncSpanCap` (decision 0076, **Search
    /// span**): (cap - length) / 2 when neither side cuts, cap - length - the near gap when one
    /// side cuts first, and nil when the whole session fits.
    private func largestSyncWithin(_ clip: Clip) throws(SessionError) -> Frames? {
        let cap = syncSpanCap
        guard clip.length <= cap else { throw .syncSpanTooLong(maxWithin: .zero) }
        let (before, after) = (clip.start, end - clip.end)
        guard clip.length + before + after > cap else { return nil }
        let near = min(before, after)
        let room = cap - clip.length
        return near + near >= room ? Frames(room.count / 2) : room - near
    }
}
