import AVFoundation
import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Observation
import SwiftUI

/// A question or an error that the window shows.
enum WindowAlert: Hashable {
    case error(StudioError)
    case microphone(MicrophoneAccess)
    case confirmStopAndClose
    case confirmUnsavedClose
    /// The report after an export: the paths of the files that rendered as silence (decision 0003).
    case exported([String])
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
    /// The Copy and Cut excerpt of this window (decision 0018): not on the macOS pasteboard,
    /// because a file ID names audio only inside its package. A close drops it.
    @ObservationIgnored var clipboard: Excerpt?
    /// The step of Export before the export runs (decision 0019). Nil: no step.
    var exportStep: ExportStep?
    /// The error of a take start that its checks refused while an export runs. The progress
    /// sheet shows it: a window alert would wait behind the sheet until the export ends.
    var recordRefusal: StudioError?
    /// The space for the finalize of the pending take, when one waits.
    private(set) var pendingSpace: (needed: Int64, free: Int64)?

    @ObservationIgnored private let recordings: ActiveRecordings?
    /// The registry: a move changes the key, and a close removes the entry.
    @ObservationIgnored private(set) weak var app: AppDelegate?
    @ObservationIgnored private(set) var window: NSWindow?
    /// The toolbar of the window (decision 0023).
    @ObservationIgnored private(set) var chrome: SessionChrome?
    /// Written by the chrome loop on a change; SwiftUI reads it in place of `Studio.play`.
    var shown = ShownChrome()
    /// The SwiftUI body runs of the window content, for the tests.
    @ObservationIgnored var bodyRuns = 0
    /// The body runs of the record-over overlay that show the warning, for the tests.
    @ObservationIgnored var overlayShows = 0
    /// The record time left of the armed tracks before a take; only
    /// `SessionChrome.refreshRecordTime()` writes it (decision 0023).
    var idleRecordTimeLeft: Duration?
    /// The commands that reach a leaf of the window, for the tests. Nil: no record.
    @ObservationIgnored var leafCalls: [String]?
    /// The lanes of the window, for the zoom commands.
    @ObservationIgnored weak var timelineView: TimelineScrollView?
    /// The zoom history and the toggles of the window (decision 0025). The window owns it, so a
    /// new pane from SwiftUI keeps it, and `timeline.canGoBack` never describes an old pane.
    @ObservationIgnored var navigation = Navigation()
    /// The last view of the lanes. A new pane shows it, so the pane makes no zoom with no entry.
    @ObservationIgnored var shownZoom: Zoom?
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
        let previous = app?.windows.values.compactMap(\.window).max { $0.windowNumber < $1.windowNumber }
        let host = NSHostingController(rootView: SessionView(model: self))
        // The content sets only the minimum size, so the window keeps its first size.
        host.sizingOptions = .minSize
        // SwiftUI must not replace the toolbar. Set before the window takes the host: after it,
        // the title bar has already lost its subtitle field (probe P5).
        host.sceneBridgingOptions = []
        let window = UndoRoutingWindow(contentViewController: host)
        window.model = self
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        chrome = SessionChrome(model: self, window: window)
        showTitle()
        window.placeAsSessionWindow(after: previous)
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
    /// The studio gets the studios of the other windows: a take ends their exports (decision 0019).
    func adopt(_ studio: Studio) {
        armed = Set(studio.session.tracks.filter { $0.route != nil }.map(\.id))
        studio.otherStudios = { [weak app, weak studio] in
            app?.windows.values.compactMap(\.studio).filter { $0 !== studio } ?? []
        }
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

    func refreshPendingSpace() async {
        pendingSpace = await idleStudio?.pendingSpace()
    }

    /// Drops the studio, so its lock goes, and breaks the cycle of the window and its view.
    private func finishClose() {
        phase = .closed
        // The pool releases the view now, not at the end of the main-queue job, so the studio
        // and its lock go before this call returns, and an open right after it works.
        autoreleasepool {
            let window = window
            self.window = nil
            chrome?.close()
            chrome = nil
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
        chrome?.refreshRecordTime()
        deviceList.changed()
        if case .open(let studio) = phase { studio.loadPeaks() }
        Task { await idleStudio?.checkMedia() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if app?.key === self { app?.key = nil }
    }
}
