import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// The track volume (F94): the fader of a header row, its VoiceOver actions, and the Track menu
/// items. The volume is the track gain in the mix, not a recording level.
extension SessionWindow {
    /// A fader drag step: the Player plays `dB` with no edit and no autosave. During a take or with
    /// no play it does nothing.
    func previewVolume(_ dB: Double, track: TrackID) {
        guard let gain = Gain(dB: dB) else { return }
        try? studio?.previewGain(gain, track: track)
    }

    /// The fader mouse-up: one edit with `dB`, then the end of the preview, so a later edit or
    /// an undo plays the session gain. Returns true for an edit.
    @discardableResult func commitVolume(_ dB: Double, track: TrackID) -> Bool {
        guard let studio, let gain = Gain(dB: dB) else { return false }
        defer { studio.endPreview() }
        let changed = studio.session.track(track).map { $0.gain != gain } ?? false
        return changed && edit({ session throws(SessionError) in try session.setGain(gain, track: track) }) != nil
    }

    /// Track > Raise, Lower, and Reset Track Volume: the tracks of the range selection, in one edit.
    /// No track, or a clip set: a beep (decision 0038).
    func changeVolume(_ command: TimelineCommand, _ studio: Studio) {
        let tracks = timeline.selection.headerTracks(in: studio.session)
        guard !tracks.isEmpty else { return beep() }
        switch command {
        case .raiseVolume: stepVolume(by: 1, tracks: tracks)
        case .lowerVolume: stepVolume(by: -1, tracks: tracks)
        case .resetVolume: setVolume(.zero, tracks: tracks)
        // `run(_:)` sends only the three volume commands here.
        default: break
        }
    }

    /// The reset of a double-click whose first click made the edit of session revision
    /// `revision`: the reset joins that edit, so the double-click is one undo step. After another
    /// edit, it is an edit of its own.
    func resetVolume(_ track: TrackID, joining revision: Int) {
        guard let studio = idleStudio, studio.sessionRevision == revision else {
            return setVolume(.zero, tracks: [track])
        }
        do throws(StudioError) {
            try studio.amend { session throws(SessionError) in try session.setGain(.zero, track: track) }
        } catch {
            alert = .error(error)
        }
    }

    /// Sets each of `tracks` to `gain` in one edit: the fader reset and a VoiceOver set value.
    func setVolume(_ gain: Gain, tracks: [TrackID]) {
        edit { session throws(SessionError) in
            for track in tracks { try session.setGain(gain, track: track) }
        }
    }

    /// Moves each of `tracks` by `delta` dB from its own value, in one edit. A step stops at the
    /// end of the fader travel; a stored value outside it does not move further out.
    func stepVolume(by delta: Double, tracks: [TrackID]) {
        edit { session throws(SessionError) in
            for track in tracks {
                guard let dB = session.track(track)?.gain.dB, let gain = Gain(dB: FaderScale.step(dB, by: delta))
                else { continue }
                try session.setGain(gain, track: track)
            }
        }
    }
}
