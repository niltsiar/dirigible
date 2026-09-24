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
    private(set) var phase: Phase = .opening
    /// True when the list of active recordings had the package at launch.
    private(set) var recovering = false
    var alert: WindowAlert?
    /// Window state, not saved: at open, the tracks with a route; a new route arms (decision 0014).
    var armed: Set<TrackID> = []
    private(set) var devices: [InputDevice] = []
    /// The space for the finalize of the pending take, when one waits.
    private(set) var pendingSpace: (needed: Int64, free: Int64)?

    @ObservationIgnored private let recordings: ActiveRecordings?
    /// The registry: a move changes the key, and a close removes the entry.
    @ObservationIgnored private weak var app: AppDelegate?
    @ObservationIgnored private(set) var window: NSWindow?
    @ObservationIgnored private var opening: Task<Void, Never>?
    /// ponytail: a poll of the device list every 2 s while the window is key and idle; the
    /// input-monitor run adds a listener.
    @ObservationIgnored private var devicePoll: Task<Void, Never>?
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
                let studio = try await Studio.open(url, recordings: recordings)
                if case .closing = phase {
                    phase = .closing(studio)
                    return
                }
                armed = Set(studio.session.tracks.filter { $0.route != nil }.map(\.id))
                phase = .open(studio)
                follow(studio)
                // Not in this task: the task holds the studio, and a close waits for it.
                Task { await refreshDevices() }
            } catch {
                if case .closing = phase { return }
                phase = .failed(error)
            }
        }
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
    func cancelUnsavedClose() {
        alert = nil
        if case .closing(let studio?) = phase { phase = .open(studio) }
    }

    /// For Quit: waits for the open, stops a take, and waits for every write.
    func settle() async {
        await opening?.value
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

    var canRetry: Bool { idleStudio?.pendingTake != nil }
    var canEdit: Bool { idleStudio != nil }
    var canUndo: Bool { idleStudio?.canUndo == true }
    var canRedo: Bool { idleStudio?.canRedo == true }

    /// Command-R. The library reads the microphone access; the app requests it (decision 0013).
    func record() async {
        guard canRecord, let studio = idleStudio else { return }
        let armed = studio.session.tracks.map(\.id).filter(armed.contains)
        // ponytail: the take goes after the last clip; the timeline run adds a playhead.
        let playhead = studio.session.tracks.flatMap(\.clips).map(\.end).max() ?? .zero
        do throws(StudioError) {
            do throws(StudioError) {
                try await studio.startRecording(armed: armed, playhead: playhead)
            } catch .microphoneAccess(let access) {
                switch microphoneStep(access) {
                case .request:
                    guard await requestMicrophoneAccess() else { throw .microphoneAccess(.denied) }
                    // The prompt waits for the user. A close can end the window meanwhile, and a
                    // take starts only in an open window with the same studio.
                    guard case .open(let current) = phase, current === studio else { return }
                    try await studio.startRecording(armed: armed, playhead: playhead)
                case .privacyLink: throw .microphoneAccess(access)
                }
            }
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

    func rename(_ track: TrackID, to name: String) {
        guard idleStudio?.session.track(track)?.name != name else { return }
        edit { s throws(SessionError) in try s.renameTrack(track, to: name) }
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

    func refreshDevices() async {
        let list = await Task.detached { InputDevice.all() }.value
        if list != devices { devices = list }
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
        devicePoll?.cancel()
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
                    let old = self.url
                    self.url = studio.url
                    self.showTitle()
                    self.app?.rekey(old, to: studio.url)
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

    func windowDidBecomeKey(_ notification: Notification) {
        app?.key = self
        devicePoll?.cancel()
        devicePoll = Task { [weak self] in
            while !Task.isCancelled {
                if self?.idleStudio != nil { await self?.refreshDevices() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if app?.key === self { app?.key = nil }
        devicePoll?.cancel()
    }
}

enum MicrophoneStep: Equatable {
    case request
    case privacyLink
}

/// Only an undecided access can change through the prompt (decision 0013).
func microphoneStep(_ access: MicrophoneAccess) -> MicrophoneStep {
    access == .notDetermined ? .request : .privacyLink
}

/// The routes of a device: mono 1 to n, then the stereo pairs (1, 2), (3, 4), and so on.
func routeOptions(channelCount: Int) -> [Route.Channels] {
    (0..<max(0, channelCount)).map { .mono($0 + 1) }
        + stride(from: 1, to: channelCount, by: 2).map { .stereo($0, $0 + 1) }
}
