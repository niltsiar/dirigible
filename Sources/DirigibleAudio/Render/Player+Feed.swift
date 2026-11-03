import DirigibleCore

/// The feed of a play and its frame math, apart from the state of the Player.
extension Player {
    /// The running play. `scheduled` counts output frames from the play start. `fadeFrom` is the
    /// session of the last scheduled chunk when a mute or solo changed after it: the next chunk
    /// crossfades from that mix (decision 0039).
    struct Feed {
        let anchor: Frames
        let shuttle: Shuttle
        /// The frame where a forward feed stops before the session end; nil: the session end.
        let end: Frames?
        /// The vari-speed that the unit plays: 1x at a tape rate, with no unit, or when the unit
        /// refuses the rate. `scheduled` counts node frames, which are source frames at any
        /// speed (probe S3).
        var speed: Speed
        /// The last change of speed with no new play, for the heard frame.
        var step: SpeedStep?
        let mix: MixReader
        var scheduled = 0
        var fadeFrom: Session?
    }

    /// The heard set or a track gain of the tracks that are in both sessions changed: a mute, solo,
    /// or fader change, or the removal of the only soloed track. A track add or remove alone keeps it.
    static func mixChanged(from old: Session, to new: Session) -> Bool {
        let shared = Set(old.tracks.map(\.id)).intersection(new.tracks.map(\.id))
        let gains = { (session: Session) in session.tracks.filter { shared.contains($0.id) }.map(\.gain) }
        return Set(old.heardTracks(in: shared).map(\.id)) != Set(new.heardTracks(in: shared).map(\.id))
            || gains(old) != gains(new)
    }

    /// The output frames of the whole feed: to the end of the play or the session end, the smaller
    /// one (forward), or to 0 (reverse).
    func length(_ feed: Feed) -> Int {
        let end = min(feed.end ?? feed.mix.session.end, feed.mix.session.end)
        let distance = feed.shuttle.direction == .forward ? end - feed.anchor : feed.anchor
        return max(0, Int((Double(distance.count) / feed.shuttle.rate.rawValue).rounded(.up)))
    }

    /// The session frame after `played` output frames of the feed.
    func frame(_ feed: Feed, played: Int) -> Frames {
        let moved = Frames(Int(Double(played) * feed.shuttle.rate.rawValue))
        return feed.shuttle.direction == .forward ? feed.anchor + moved : feed.anchor - moved
    }
}
