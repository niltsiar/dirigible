import DirigibleAudio
import DirigibleCore

/// The actions of the session window and the rules that turn them on (decision 0014). Each
/// action maps to a `Studio` call.
extension SessionWindow {
    /// The studio when it takes a command: open, no take, no start.
    var idleStudio: Studio? {
        guard case .open(let studio) = phase, studio.isIdle else { return nil }
        return studio
    }

    /// Off while the export question or the save panel shows: one Cancel frees it, and a take
    /// would drop the typed name. On while the media check or the export runs (decision 0019).
    var canRecord: Bool {
        guard exportStep == nil || exportStep == .checking else { return false }
        guard let studio = idleStudio, studio.pendingTake == nil else { return false }
        return studio.session.tracks.contains { armed.contains($0.id) }
    }

    /// The armed tracks with a route, in session order: the tracks that a take records.
    var armedWithRoute: [TrackID] {
        studio?.session.tracks.filter { armed.contains($0.id) && $0.route != nil }.map(\.id) ?? []
    }

    var canStop: Bool {
        guard case .open(let studio) = phase, case .recording = studio.transport else { return false }
        return true
    }

    /// Input Levels: only in the open phase, like the other Record items.
    var canMonitor: Bool {
        if case .open = phase { return true }
        return false
    }

    var canRetry: Bool { idleStudio?.pendingTake != nil }
    var canEdit: Bool { idleStudio != nil }
    var canUndo: Bool { idleStudio?.canUndo == true }
    var canRedo: Bool { idleStudio?.canRedo == true }

    /// Command-R. The library reads the microphone access; the app requests it (decision 0013).
    func record() async {
        commitDrafts()
        guard canRecord, let studio = idleStudio else { return }
        // The take form removes the name field, so its focus change cannot end a rename with no
        // typed text (run 2026-10-11-ui-polish-header code gate 1).
        renamingTrack = nil
        let armed = studio.session.tracks.map(\.id).filter(armed.contains)
        do throws(StudioError) {
            // The take starts at the Studio playhead; a play stops first (decision 0016).
            try await withMicrophoneAccess(studio) { () async throws(StudioError) in
                try await studio.startRecording(armed: armed)
            }
            exportReport = nil
            chapterWarnings = nil
        } catch let error where studio.exportProgress != nil {
            // A refused start keeps the export, and its sheet hides a window alert until the end.
            recordRefusal = error
        } catch .microphoneAccess(let access) {
            alert = .microphone(access)
        } catch {
            alert = .error(error)
        }
    }

    /// A finalize error keeps the take pending, and the take banner shows it.
    func stop() async {
        guard canStop else { return }
        try? await studio?.stopRecording()
    }

    func retry() async {
        commitDrafts()
        guard canRetry else { return }
        // The finalize removes the name field, as in record().
        renamingTrack = nil
        try? await idleStudio?.retryFinalize()
        await refreshPendingSpace()
    }

    func undo() { perform { studio throws(StudioError) in try studio.undo() } }
    func redo() { perform { studio throws(StudioError) in try studio.redo() } }

    func addTrack() {
        edit { s throws(SessionError) in
            try s.addTrack(name: L10n.trackDefaultName.format(s.tracks.count + 1), layout: .mono)
        }
    }

    /// Saves the typed name of the track. The draft goes also when the rename is refused, so
    /// the field shows the saved name again. The rename of the track ends, also with no draft.
    func commitName(_ track: TrackID) {
        if renamingTrack == track { renamingTrack = nil }
        guard let name = drafts.removeValue(forKey: track), idleStudio?.session.track(track)?.name != name else {
            return
        }
        edit { s throws(SessionError) in try s.renameTrack(track, to: name) }
    }

    /// Record, Close, Quit, Auto Level, Place, Retry, an import (the menu or a drop), a paste from
    /// another package, a revert to a backup, and a mouse-down on the lanes save each typed name
    /// and the typed inspector values first, also with the focus still in its field. The generic menu entry run(_:) and the
    /// Transport menu commit only the inspector values; Remove Track drops the name drafts of its
    /// tracks. A refused episode draft stays: Close and Quit stop on it (`holdsRefusedEpisode`),
    /// and the other actions go on without it.
    func commitDrafts() {
        for track in drafts.keys { commitName(track) }
        commitInspector()
    }

    /// A route sets the layout of its channels, and it arms the track.
    func setRoute(_ channels: Route.Channels?, device: InputDevice?, track: TrackID) {
        guard let channels, let device else {
            edit { s throws(SessionError) in try s.setRoute(nil, track: track) }
            armed.remove(track)
            return
        }
        let route = Route.device(uid: device.uid, channels: channels)
        edit { s throws(SessionError) in try s.setLayout(channels.layout, route: route, track: track) }
        if idleStudio?.session.track(track)?.route == route { armed.insert(track) }
    }

    /// Runs the edit on an idle studio. Nil when the studio is not idle (no alert), or after a
    /// throw (with its alert). A `ripple` that Studio refuses under a pending or split take beeps.
    @discardableResult func edit<Result>(
        ripple: Bool = false, _ body: (inout Session) throws(SessionError) -> Result
    ) -> Result? {
        guard let studio = idleStudio else { return nil }
        do throws(StudioError) {
            return try studio.edit(ripple: ripple, body)
        } catch .rippleBlocked {
            beep()
            return nil
        } catch {
            alert = .error(error)
            return nil
        }
    }

    private func perform(_ action: (Studio) throws(StudioError) -> Void) {
        guard let studio = idleStudio else { return }
        do { try action(studio) } catch { alert = .error(error) }
    }
}
