import DirigibleCore

/// Mute or solo, the two flags of a track (decision 0039).
enum TrackFlag: CaseIterable {
    case muted, soloed

    func isOn(_ track: Track) -> Bool { self == .muted ? track.isMuted : track.isSoloed }

    func set(_ on: Bool, _ tracks: [TrackID], in session: inout Session) throws(SessionError) {
        switch self {
        case .muted: try session.setMuted(on, tracks: tracks)
        case .soloed: try session.setSoloed(on, tracks: tracks)
        }
    }

    /// The VoiceOver label of the button of `name`: "Mute Host".
    func label(_ name: String) -> String { (self == .muted ? L10n.trackMuteLabel : .trackSoloLabel).format(name) }
}

extension SessionWindow {
    /// The M or S button of a header row: one edit, so one undo entry and an autosave. With `all`
    /// (Option-click) every track gets the new state. During a take it does nothing.
    func setFlag(_ flag: TrackFlag, _ on: Bool, track: TrackID, all: Bool) {
        edit(ripple: false) { session throws(SessionError) in
            try flag.set(on, all ? session.tracks.map(\.id) : [track], in: &session)
        }
    }

    /// Track > Mute Track and Solo Track: the tracks of the range selection. When one of them is
    /// off, all go on; else all go off. No track, or a clip set: a beep (decision 0038).
    func toggleFlag(_ flag: TrackFlag) {
        guard let studio else { return }
        let tracks = timeline.selection.headerTracks(in: studio.session)
        guard !tracks.isEmpty else { return beep() }
        let on = tracks.contains { studio.session.track($0).map { !flag.isOn($0) } ?? false }
        edit(ripple: false) { session throws(SessionError) in try flag.set(on, tracks, in: &session) }
    }
}
