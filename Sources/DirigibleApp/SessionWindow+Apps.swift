import AppKit
import DirigibleAudio
import DirigibleCore

/// The app sources of the session window: the Apps section of the route menu (A15), the app
/// name of a track, and the System Audio Recording pane (A9).
extension SessionWindow {
    /// Reads the running apps off the main actor; a focus and a route menu that opens call it.
    /// It also reads the bundle name of each routed app that does not run, so a waiting track
    /// shows a name.
    func refreshApps() {
        let (read, readName) = (readApps, readAppName)
        let routed =
            studio?.session.tracks.compactMap { track -> String? in
                if case .app(let bundleID) = track.route { bundleID } else { nil }
            } ?? []
        Task {
            let (list, names) = await Task.detached {
                let list = read()
                let missing = routed.filter { id in !list.contains { $0.bundleID == id } }
                return (list, missing.map { ($0, readName($0)) })
            }.value
            for (id, name) in names { appNames[id] = name }
            for app in list { appNames[app.bundleID] = app.name }
            if list != apps { apps = list }
        }
    }

    /// The name of an app from the last lists, else its bundle ID.
    func appName(_ bundleID: String) -> String { appNames[bundleID] ?? bundleID }

    /// An app route keeps the track layout (a mono or a stereo mixdown, decision 0029), and it
    /// arms the track, as a device route.
    func setAppRoute(_ bundleID: String, track: TrackID) {
        let route = Route.app(bundleID: bundleID)
        edit { s throws(SessionError) in try s.setRoute(route, track: track) }
        if idleStudio?.session.track(track)?.route == route { armed.insert(track) }
    }

    /// Privacy & Security > System Audio Recording.
    func openAudioCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// An item of the Apps section of the route menu.
enum AppMenuItem: Hashable {
    case app(bundleID: String, name: String)
    /// macOS 14.0 and 14.1 have no process taps: one disabled item (A14).
    case unavailable
}

/// A15: one item for each running app of the list (by name, without Dirigible: the list leaves
/// out this process), or the macOS floor.
func appMenuItems(_ apps: [RunningApp], tapsAvailable: Bool) -> [AppMenuItem] {
    tapsAvailable ? apps.map { .app(bundleID: $0.bundleID, name: $0.name) } : [.unavailable]
}
