import DirigibleCore

/// The frame math of a feed, apart from the state of the Player.
extension Player {
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
