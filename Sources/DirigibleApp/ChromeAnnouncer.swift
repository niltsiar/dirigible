import AppKit
import DirigibleAudio
import DirigibleCore

/// What VoiceOver hears from the chrome loop (decision 0023): each announcement is made once for
/// its change, so the state of the last one is kept here. `SessionChrome` calls it at each turn.
struct ChromeAnnouncer {
    /// The tracks of the last record-over warning that was announced. Only a different, not empty
    /// set of tracks announces again: a play across a clip end changes the clip, not the tracks.
    private var recordOver: [TrackID] = []
    /// The tracks whose **No sound from** or **No access** was announced, with that state, and the
    /// take state of that time. A track leaves the map with its live entry, at a take start or end
    /// (new writers), and when it leaves the warning with a sound. So a rearm or a come back with
    /// no sound announces nothing, and only a change to the other warning announces again.
    private var warnings: [TrackID: LiveTrack.State] = [:]
    private var inTake = false
    /// The pre-roll of a take was announced: "Pre-roll" once at the press.
    private var preRoll = false
    /// The last take whose end was announced.
    private var take: Int?

    /// Announces what `state` changes against the shown state of `model`. The caller then writes
    /// `state.shown` to the model.
    @MainActor mutating func announce(
        _ state: ChromeState, model: SessionWindow,
        post: @MainActor (String, NSAccessibilityPriorityLevel) -> Void
    ) {
        if model.canStop != inTake {
            inTake = model.canStop
            warnings = [:]
        }
        if state.preRolling != preRoll {
            preRoll = state.preRolling
            if state.preRolling { post(L10n.subtitlePreRoll.text, .medium) }
        }
        if let finished = state.finishedTake, finished != take {
            take = finished
            post(L10n.takeEnded.format(finished), .medium)
        }
        if let studio = model.studio {
            warnings = warnings.filter { studio.liveStates[$0.key] != nil }
        }
        guard model.shown != state.shown else { return }
        announceAppWarnings(state.shown.appWarnings, before: model.shown.appWarnings, model: model, post: post)
        // A banner of a kind that did not show is announced once.
        for banner in state.shown.banners where !model.shown.banners.contains(where: { $0.key == banner.key }) {
            if let priority = banner.announcement { post(banner.spoken, priority) }
        }
        let tracks = state.shown.recordOver.reached.map(\.track)
        if !tracks.isEmpty, tracks != recordOver {
            recordOver = tracks
            post(state.shown.recordOver.detail, .high)
        }
    }

    /// Announces each app track that enters `.noSound` or `.noAccess` and was not announced in
    /// that state. A track that leaves the warning with a live peak above 0 can announce again:
    /// the drain reports the levels first.
    @MainActor private mutating func announceAppWarnings(
        _ appWarnings: [TrackID: LiveTrack.State], before: [TrackID: LiveTrack.State], model: SessionWindow,
        post: @MainActor (String, NSAccessibilityPriorityLevel) -> Void
    ) {
        guard let studio = model.studio else { return }
        for track in before.keys where appWarnings[track] == nil && (studio.liveTracks[track]?.peak ?? 0) > 0 {
            warnings[track] = nil
        }
        for track in studio.session.tracks {
            guard let state = appWarnings[track.id], state != before[track.id], state != warnings[track.id],
                case .app(let bundleID) = track.route, let text = HeaderStateText.app(state, model.appName(bundleID))
            else { continue }
            warnings[track.id] = state
            post(text.full, .high)
        }
    }
}

/// Posts a VoiceOver announcement of the app.
@MainActor func postAnnouncement(_ text: String, priority: NSAccessibilityPriorityLevel) {
    NSAccessibility.post(
        element: NSApp as Any, notification: .announcementRequested,
        userInfo: [.announcement: text, .priority: priority.rawValue])
}
