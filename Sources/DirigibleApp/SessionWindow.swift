import AVFoundation
import AppKit
import DirigibleAudio
import DirigibleCore
import Observation
import SwiftUI

/// A question or an error that the window shows.
enum WindowAlert: Hashable {
    case error(StudioError)
    case microphone(MicrophoneAccess)
    case confirmStopAndClose
    case confirmUnsavedClose
}

/// The state of one session window and its `NSWindowDelegate` (decision 0014). `Studio` is the
/// model; this type adds only window state and maps the actions to `Studio` calls.
@Observable @MainActor final class SessionWindow: NSObject, NSWindowDelegate {
    enum Phase {
        case opening
        case open(Studio)
        case failed(StudioError)
        /// Nil: the open had not returned when the close started.
        case closing(Studio?)
        case closed
    }

    /// The package path in `packageIdentity` form. It follows `Studio.url` after a move.
    private(set) var url: URL
    /// Each change to `.open` (the open, a cancelled close) sends the monitor request, so a
    /// toggle change in another phase reaches the studio.
    private(set) var phase: Phase = .opening {
        didSet {
            if case .open = phase { Task { await updateMonitor() } }
        }
    }
    /// True when the list of active recordings had the package at launch.
    private(set) var recovering = false
    var alert: WindowAlert?
    /// Window state, not saved: at open, the tracks with a route; a new route arms (decision 0014).
    var armed: Set<TrackID> = []
    /// The typed name of each track that no rename has saved yet. A name field shows its draft,
    /// else the saved name.
    var drafts: [TrackID: String] = [:]
    /// Monitor Inputs (decision 0015): off at open, not saved. With the armed tracks, it drives
    /// `Studio.monitor(armed:)`.
    var monitoring = false
    /// The input devices of the menus, from the process device list.
    var devices: [InputDevice] { deviceList.devices }
    /// The marks, the zoom, Automatic Scroll, and the view of the timeline (decision 0017). Not
    /// saved.
    var timeline = TimelineState()
    /// The space for the finalize of the pending take, when one waits.
    private(set) var pendingSpace: (needed: Int64, free: Int64)?

    @ObservationIgnored private let recordings: ActiveRecordings?
    /// The registry: a move changes the key, and a close removes the entry.
    @ObservationIgnored private weak var app: AppDelegate?
    @ObservationIgnored private(set) var window: NSWindow?
    /// The lanes of the window, for the zoom commands.
    @ObservationIgnored weak var timelineView: TimelineScrollView?
    @ObservationIgnored private var opening: Task<Void, Never>?
    /// Tests give their own list.
    @ObservationIgnored var deviceList = DeviceList.shared
    /// The macOS microphone prompt (decision 0013). Tests give their own.
    @ObservationIgnored var requestMicrophoneAccess: () async -> Bool = {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    init(url: URL, recordings: ActiveRecordings?, app: AppDelegate) {
        self.url = url
        self.recordings = recordings
        self.app = app
    }

    /// The studio of an open window, also while a close waits for it.
    var studio: Studio? {
        switch phase {
        case .open(let studio): studio
        case .closing(let studio): studio
        case .opening, .failed, .closed: nil
        }
    }

    /// A take starts or records: a close or a quit asks first.
    var isTakeRunning: Bool {
        guard let studio else { return false }
        if case .recording = studio.transport { return true }
        return studio.isStarting
    }

    func show() {
        let window = UndoRoutingWindow(contentViewController: NSHostingController(rootView: SessionView(model: self)))
        window.model = self
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        showTitle()
        window.makeKeyAndOrderFront(nil)
    }

    func bringToFront() { window?.makeKeyAndOrderFront(nil) }

    /// Opens the package off the main actor (`Studio.open` runs the recovery).
    func open(recovering: Bool) {
        self.recovering = recovering
        phase = .opening
        opening = Task {
            do throws(StudioError) {
                let studio = try await Studio.open(url, recordings: recordings, peakCache: app?.peakCache)
                if case .closing = phase {
                    phase = .closing(studio)
                    return
                }
                adopt(studio)
            } catch {
                if case .closing = phase { return }
                phase = .failed(error)
            }
        }
    }

    /// Shows an open studio: each track with a route arms, and the window follows `Studio.url`.
    func adopt(_ studio: Studio) {
        armed = Set(studio.session.tracks.filter { $0.route != nil }.map(\.id))
        phase = .open(studio)
        follow(studio)
        followMonitor(studio)
    }

    /// The close button and Close: during a take, ask first.
    func requestClose() {
        if case .closing = phase { return }
        if isTakeRunning {
            alert = .confirmStopAndClose
            return
        }
        Task { await close() }
    }

    /// Waits for the open, stops a take, and waits for every write. When the last save failed,
    /// it asks before it closes.
    func close() async {
        commitNames()
        alert = nil
        switch phase {
        case .closing, .closed: return
        case .failed:
            finishClose()
            return
        case .opening, .open: phase = .closing(studio)
        }
        await opening?.value
        guard case .closing(let studio) = phase else { return }
        if let studio {
            // `settle` empties the monitor request, so the toggle goes off too.
            monitoring = false
            await studio.settle()
            if studio.saveError != nil {
                alert = .confirmUnsavedClose
                return
            }
        }
        finishClose()
    }

    /// "Close anyway?": Close.
    func closeAnyway() {
        alert = nil
        finishClose()
    }

    /// "Close anyway?": Cancel. The window stays open with the same studio, which keeps its lock.
    /// The settle of the close started no peak pass, so the files of a take that it finalized
    /// get their peaks now (decision 0017).
    func cancelUnsavedClose() {
        alert = nil
        guard case .closing(let studio?) = phase else { return }
        phase = .open(studio)
        studio.loadPeaks()
    }

    /// For Quit: waits for the open, turns the monitor off, stops a take, and waits for every
    /// write.
    func settle() async {
        await opening?.value
        commitNames()
        monitoring = false
        await studio?.settle()
    }

    // MARK: Actions

    /// The studio when it takes a command: open, no take, no start.
    private var idleStudio: Studio? {
        guard case .open(let studio) = phase, studio.transport == .idle, !studio.isStarting else { return nil }
        return studio
    }

    var canRecord: Bool {
        guard let studio = idleStudio, studio.pendingTake == nil else { return false }
        return studio.session.tracks.contains { armed.contains($0.id) }
    }

    var canStop: Bool {
        guard case .open(let studio) = phase, case .recording = studio.transport else { return false }
        return true
    }

    /// Monitor Inputs: only in the open phase, like the other Record items.
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
        commitNames()
        guard canRecord, let studio = idleStudio else { return }
        let armed = studio.session.tracks.map(\.id).filter(armed.contains)
        do throws(StudioError) {
            // The take starts at the Studio playhead; a play stops first (decision 0016).
            try await withMicrophoneAccess(studio) { () async throws(StudioError) in
                try await studio.startRecording(armed: armed)
            }
        } catch .microphoneAccess(let access) {
            alert = .microphone(access)
        } catch {
            alert = .error(error)
        }
    }

    /// Runs `body`. When it throws an undecided access, it shows the macOS prompt and runs `body`
    /// once more after a grant (decision 0013). The prompt waits for the user; a close can end
    /// the window meanwhile, so `body` runs again only in an open window with the same studio.
    func withMicrophoneAccess(_ studio: Studio, _ body: () async throws(StudioError) -> Void)
        async throws(StudioError)
    {
        do throws(StudioError) {
            try await body()
        } catch .microphoneAccess(let access) {
            switch microphoneStep(access) {
            case .request:
                guard await requestMicrophoneAccess() else { throw .microphoneAccess(.denied) }
                guard case .open(let current) = phase, current === studio else { return }
                try await body()
            case .privacyLink: throw .microphoneAccess(access)
            }
        }
    }

    /// A finalize error keeps the take pending, and the take banner shows it.
    func stop() async {
        guard canStop else { return }
        try? await studio?.stopRecording()
    }

    func retry() async {
        guard canRetry else { return }
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
    /// the field shows the saved name again.
    func commitName(_ track: TrackID) {
        guard let name = drafts.removeValue(forKey: track), idleStudio?.session.track(track)?.name != name else {
            return
        }
        edit { s throws(SessionError) in try s.renameTrack(track, to: name) }
    }

    /// Record, Close, and Quit save each typed name first, also a name with no Return and with
    /// the focus still in its field.
    private func commitNames() {
        for track in drafts.keys { commitName(track) }
    }

    /// A route sets the layout of its channels, and it arms the track.
    func setRoute(_ channels: Route.Channels?, device: InputDevice?, track: TrackID) {
        guard let channels, let device else {
            edit { s throws(SessionError) in try s.setRoute(nil, track: track) }
            armed.remove(track)
            return
        }
        let route = Route(deviceUID: device.uid, channels: channels)
        edit { s throws(SessionError) in try s.setLayout(channels.layout, route: route, track: track) }
        if idleStudio?.session.track(track)?.route == route { armed.insert(track) }
    }

    func refreshPendingSpace() async {
        pendingSpace = await idleStudio?.pendingSpace()
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func edit(_ body: (inout Session) throws(SessionError) -> Void) {
        perform { studio throws(StudioError) in try studio.edit(body) }
    }

    private func perform(_ action: (Studio) throws(StudioError) -> Void) {
        guard let studio = idleStudio else { return }
        do { try action(studio) } catch { alert = .error(error) }
    }

    /// Drops the studio, so its lock goes, and breaks the cycle of the window and its view.
    private func finishClose() {
        phase = .closed
        // The pool releases the view now, not at the end of the main-queue job, so the studio
        // and its lock go before this call returns, and an open right after it works.
        autoreleasepool {
            let window = window
            self.window = nil
            window?.close()
            window?.contentViewController = nil
        }
        app?.forget(self)
    }

    /// Follows `Studio.url`: a write into a moved package changes it (decision 0014).
    private func follow(_ studio: Studio) {
        withObservationTracking {
            _ = studio.url
        } onChange: { [weak self, weak studio] in
            Task { @MainActor in
                guard let self, let studio, self.studio === studio else { return }
                if studio.url != self.url {
                    self.url = studio.url
                    self.showTitle()
                    self.app?.rekey(self, to: studio.url)
                }
                self.follow(studio)
            }
        }
    }

    private func showTitle() {
        window?.title = url.deletingPathExtension().lastPathComponent
        window?.representedURL = url
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose()
        return false
    }

    /// A focus reads the device list again, so a channel change of a present device shows, and
    /// checks the media, so a file that the user put back shows (decision 0016). It loads the
    /// peaks again, because a WAV can change outside the app (decision 0017).
    func windowDidBecomeKey(_ notification: Notification) {
        app?.key = self
        deviceList.changed()
        if case .open(let studio) = phase { studio.loadPeaks() }
        Task { await idleStudio?.checkMedia() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if app?.key === self { app?.key = nil }
    }
}
