import DirigibleAudio
import DirigibleCore

/// Track > Monitor Track (decision 0044): the window side of the record monitor.
extension SessionWindow {
    /// The tracks of the item: the header tracks of the range selection.
    private var listenSelection: [TrackID] {
        guard case .open(let studio) = phase else { return [] }
        return timeline.selection.headerTracks(in: studio.session)
    }

    /// In the open phase, also during a take (A17): each selected track has a device route (A16,
    /// A23).
    var canListen: Bool {
        guard case .open(let studio) = phase else { return false }
        let tracks = listenSelection
        return !tracks.isEmpty && tracks.allSatisfy { isDeviceTrack($0, in: studio) }
    }

    /// The check mark of the item: each selected track plays its input.
    var listensSelection: Bool {
        let tracks = listenSelection
        return !tracks.isEmpty && tracks.allSatisfy(listened.contains)
    }

    /// When one selected track is off, all go on; else all go off. `followMonitor` sends the
    /// change to the studio.
    func toggleListen() {
        guard canListen else { return }
        let tracks = Set(listenSelection)
        if tracks.isSubset(of: listened) { listened.subtract(tracks) } else { listened.formUnion(tracks) }
    }

    /// The Monitor box of a header row: its own track, or with `all` (an Option-click) every
    /// device track.
    func setListen(_ on: Bool, track: TrackID, all: Bool = false) {
        let tracks =
            all ? studio.map { s in s.session.tracks.map(\.id).filter { isDeviceTrack($0, in: s) } } ?? [] : [track]
        if on { listened.formUnion(tracks) } else { listened.subtract(tracks) }
    }

    /// The listened tracks with a device route, in session order. A route edit can make a
    /// listened track an app track or a track with no route: `updateMonitor` removes it from
    /// `listened`.
    func listenedDeviceTracks(_ studio: Studio) -> [TrackID] {
        studio.session.tracks.map(\.id).filter { listened.contains($0) && isDeviceTrack($0, in: studio) }
    }

    private func isDeviceTrack(_ id: TrackID, in studio: Studio) -> Bool {
        if case .device = studio.session.track(id)?.route { true } else { false }
    }
}

/// The text of a listened track that plays no monitor sound: no device or output, or a loopback.
/// A meter fault of the track shows first, so the header shows one text.
func listenQuietText(live: LiveTrack?, quiet: Bool, loopback: Bool) -> String? {
    guard quiet || loopback else { return nil }
    switch live?.state {
    case nil, .recording, .monitoring: return (loopback ? L10n.trackListenLoopback : L10n.trackListenQuiet).text
    default: return nil
    }
}
