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

    /// The call preset (B1c): Host on channel 1 of the default input device (no route when the
    /// device list does not have it) and Guest on `app`, in one undo entry. It saves each typed
    /// name first, as Record does. It arms each routed new track whose channels no armed track
    /// takes, so Record does not fail with `channelInUse`; the route stays.
    func addCallTracks(app: String?) {
        guard canEdit, let session = idleStudio?.session else { return }
        commitNames()
        let input = deviceList.defaults.inputUID.flatMap { uid in devices.contains { $0.uid == uid } ? uid : nil }
        let taken = session.tracks.filter { armed.contains($0.id) }.reduce(into: Set<Route>()) {
            $0.formUnion(takenChannels($1.route))
        }
        let names = (host: L10n.trackNameHost.text, guest: L10n.trackNameGuest.text)
        guard
            let added = edit({ s throws(SessionError) -> [TrackID] in
                let (host, guest) = (TrackID(), TrackID())
                try s.addCallTracks(
                    host: host, guest: guest, names: names, hostDevice: input.map { ($0, 1) }, guestApp: app)
                return [host, guest]
            })
        else { return }
        for id in added {
            if let route = idleStudio?.session.track(id)?.route, takenChannels(route).isDisjoint(with: taken) {
                armed.insert(id)
            }
        }
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

/// The channels that a route takes in a take, as `checkRoutes` counts them, one mono device route
/// per channel. An app route takes the mixdown channels of its layout, and both layouts take
/// channel 1, so two routes of one app always overlap.
func takenChannels(_ route: Route?) -> Set<Route> {
    switch route {
    case nil: []
    case .device(let uid, let channels): Set(channels.numbers.map { .device(uid: uid, channels: .mono($0)) })
    case .app(let bundleID): [.app(bundleID: bundleID)]
    }
}

/// An item of the Add Call Tracks menu (B1c).
enum CallMenuItem: Hashable {
    case app(bundleID: String, name: String)
    /// No running app: one disabled item.
    case noApps
    /// macOS 14.0 and 14.1 have no process taps: one disabled item (A14).
    case unavailable
    case divider
    /// Guest with no route.
    case noApp
}

/// One item for each running app, a divider, and No App.
func callMenuItems(_ apps: [RunningApp], tapsAvailable: Bool) -> [CallMenuItem] {
    let items: [CallMenuItem] =
        !tapsAvailable
        ? [.unavailable] : apps.isEmpty ? [.noApps] : apps.map { .app(bundleID: $0.bundleID, name: $0.name) }
    return items + [.divider, .noApp]
}
