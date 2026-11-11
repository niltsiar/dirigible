import AVFoundation
import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import DirigibleTimeline
import Observation
import SwiftUI

/// The state of one session window and its `NSWindowDelegate` (decision 0014). `Studio` is the
/// model; this type adds only window state and maps the actions to `Studio` calls.
@Observable @MainActor final class SessionWindow: NSObject {
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
    var phase: Phase = .opening {
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
    /// The track whose name field takes the text focus: a double-click on the name, Track > Rename
    /// Track, or the Rename action sets it, and the commit of its name clears it. Else a click on
    /// the name selects the track.
    var renamingTrack: TrackID?
    /// The last mouse-down on the track headers, from `HeaderHost`: a header tap reads its click
    /// count and modifier keys.
    @ObservationIgnored var headerMouseDown: NSEvent?
    /// Input Levels (decision 0015): off at open, not saved. With the armed tracks, it drives
    /// `Studio.monitor(armed:)`.
    var monitoring = false
    /// Track > Monitor Track (decision 0044): the tracks whose input plays in the default output.
    /// Off at open, not saved.
    var listened: Set<TrackID> = []
    /// The input devices of the menus, from the process device list.
    var devices: [InputDevice] { deviceList.devices }
    /// The marks, the zoom, Automatic Scroll, and the view of the timeline (decision 0017). Not
    /// saved.
    var timeline = TimelineState()
    /// View > Show Loudness Meter (decision 0033): the app preference at open.
    var showsLoudness = true
    /// View > Show Inspector (run 11b-2): the app preference at open.
    var showsInspector = false
    /// The inspector width (decision 0023): the app preference at open, then the handle.
    var inspectorWidth = InspectorWidth.standard
    /// The width of the track headers (decision 0023): read from the preferences once, in `init`.
    /// `TrackHeaderRuler` writes each change here, and a pane that SwiftUI builds again starts with
    /// it, so the record-over chip over the header corner has the width of the headers.
    var headerWidth = HeaderWidth.standard
    /// The drag of the inspector handle.
    @ObservationIgnored var inspectorDrag = PaneDrag<InspectorWidth>()
    /// The target width of an inspector drag, nil when idle. Not observed: a drag event runs no
    /// SwiftUI body (C16).
    @ObservationIgnored var inspectorPreview: InspectorWidth?
    /// The fitted width that the pointer asks for in an inspector drag, before the Transcript tab
    /// minimum: the up saves it. Nil when idle or before the first drag.
    @ObservationIgnored var inspectorRequest: InspectorWidth?
    /// The line at the target edge during an inspector drag, over the window content.
    @ObservationIgnored let inspectorGuide = CALayer()
    /// The typed text of the inspector field that no commit has saved yet.
    var inspectorDraft: InspectorDraft?
    /// The inspector field with the focus, from the pane.
    @ObservationIgnored var inspectorFocus: InspectorField?
    /// The tab of the inspector. Not saved.
    var inspectorTab = InspectorTab.clip
    /// The state of the Transcript pane (decision 0023).
    let transcriptFollow = TranscriptFollow()
    /// The typed text of the episode field that no commit has saved yet.
    var episodeDraft: EpisodeDraft?
    /// The episode field with the focus, from the pane.
    @ObservationIgnored var episodeFocus: EpisodeField?
    /// The episode field that gets the focus at the next pane update: Title for File > Episode
    /// Info…, or the field of a refused draft.
    var episodeFocusRequest: EpisodeField?
    /// The count of tab changes that a refused episode draft stopped. The tab picker takes it as
    /// its identity: the segmented control shows the segment of the click until SwiftUI makes it
    /// again (on-screen check, code gate 2).
    var heldTabChanges = 0
    /// The typed text of the Marker pane, the field with the focus, and the field that gets the
    /// focus at the next pane update (Name for Marker Info…).
    var markerDraft: MarkerDraft?
    @ObservationIgnored var markerFocus: MarkerField?
    var markerFocusRequest: MarkerField?
    /// The body runs of the inspector, for the tests. A tree check shows only that a hidden pane
    /// is gone; this count also shows one run per Marks change of a shown pane (W7).
    @ObservationIgnored var inspectorRuns = 0
    /// The observer of `NSApplication.didBecomeActiveNotification` (`followActivation()`).
    @ObservationIgnored var activeObserver: (any NSObjectProtocol)?
    /// The wait before the banner of a paste from another package shows (`ui-panel.md` item 1:
    /// 0.5 s, so a clone shows none). Tests give a wait that they end.
    @ObservationIgnored var bannerWait: @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(500)) }
    /// The sound of a refused typed number. Tests count it.
    @ObservationIgnored var beep: () -> Void = { NSSound.beep() }
    /// The loudness strip while SwiftUI keeps it; the display tick draws it.
    @ObservationIgnored weak var loudnessStrip: LoudnessStrip?
    /// The excerpt of the one clipboard of the app (decision 0042). Only `copy(_:)` writes it.
    var clipboard: Excerpt? { app?.clipboard?.excerpt }

    /// Puts `excerpt` of this studio on the one clipboard of the app, with the package and the
    /// identity of this studio. A Copy or a Cut with no excerpt does not call it, so the clipboard
    /// of another package stays.
    func copy(_ excerpt: Excerpt, of studio: Studio) { app?.clipboard = studio.clipboard(of: excerpt) }
    /// The step of Export before the export runs (decision 0019). Nil: no step.
    var exportStep: ExportStep?
    /// The last clean export with a target (decision 0032), its chapter warnings, and its split result, for
    /// their banners. The next export or take start removes them; each shows at its session revision only.
    var exportReport: ExportReportShown?
    var chapterWarnings: ChapterWarningsShown?
    var exportSet: ExportSetShown?
    /// The cues that the last Export Transcript left out, for its banner at its session revision.
    var transcriptLeftOut: TranscriptLeftOutShown?
    /// The last Auto Level, for its banner. The next Auto Level and the next take start remove it;
    /// the banner shows only at its session revision.
    var levelReport: LevelReportShown?
    /// The last Reduce Noise, for its banner at its session revision.
    var denoiseReport: DenoiseReportShown?
    @ObservationIgnored var denoisePresses = 0
    /// The values of the Reduce Noise sheet while it shows (decision 0054).
    var denoiseDraft: DenoiseDraft?
    /// The last Repair Sound for its banner, and the values of its sheet while it shows (decision 0064).
    var repairReport: RepairReportShown?
    var repairDraft: RepairDraft?
    /// The last Level Over Time, for its banner at its session revision.
    var rideReport: RideReportShown?
    /// The number of Level Over Time runs of this window, for the key of its banner.
    @ObservationIgnored var ridePresses = 0
    /// The first values of the Duck Music Under Speech sheet while it shows (decision 0060).
    var duckDraft: DuckDraft?
    /// The values of the Go to Take Time sheet while it shows (decision 0061).
    var takeTimeDraft: TakeTimeDraft?
    /// The fraction of the duck of this window while it runs, for its banner. Nil: no duck of
    /// this window runs, so an agent duck shows no bar.
    var duckProgress: Double?
    /// The banner of the last duck with no speech or with a speech file that did not read. The
    /// next duck and the next take start remove it; the banner shows only at its session revision.
    var duckReport: DuckReportShown?
    /// The list of File > Remove Unused Files while its sheet shows (decision 0047).
    var unusedFiles: UnusedFiles?
    /// The last Remove Unused Files, for its banners at its session revision.
    var pruneReport: PruneReportShown?
    @ObservationIgnored var levelPresses = 0
    /// The number of ducks of this window, for the key of the duck banner.
    @ObservationIgnored var duckPresses = 0
    /// The running import (decision 0040). Nil: no import.
    var importJob: ImportJob?
    /// The Transcribe sheet, job, and notice (decision 0065), and the Silences tab (decision 0066).
    let transcribe = TranscribeState()
    let silences: SilenceState
    let leadingPane: LeadingPaneState
    /// The error of a take start that its checks refused while an export runs. The progress
    /// sheet shows it: a window alert would wait behind the sheet until the export ends.
    var recordRefusal: StudioError?
    /// The record request of an agent that waits or starts (decision 0048), or nil.
    var consent: ConsentRequest?
    /// The agent of a request that ended with no answer, until the next edit (decision 0048).
    var consentExpired: ConsentExpiredShown?
    /// The wait of the answer time of a request. Tests hold it with a gate.
    @ObservationIgnored var consentWait: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    @ObservationIgnored var attention = ConsentAttention()
    @ObservationIgnored var notice = AgentTakeNotice()
    /// The window grant of an agent and its clock (decision 0050).
    var agentRecord = AgentRecordState()
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
    /// The body runs of the track headers and of their rows, for the tests: a header width change
    /// that keeps the layout and a range drag over the same tracks run none (code gate 3, C16).
    @ObservationIgnored var headerRuns = (headers: 0, rows: 0)
    /// The body runs of the record-over chip that show the warning, for the tests.
    @ObservationIgnored var overlayShows = 0
    /// The period of the take banner content in seconds, and its runs. Tests shorten the period.
    @ObservationIgnored var bannerTick = 1.0
    @ObservationIgnored var bannerRuns = 0
    /// The record time left of the armed tracks before a take; only
    /// `SessionChrome.refreshRecordTime()` writes it (decision 0023).
    var idleRecordTimeLeft: Duration?
    /// The commands that reach a leaf of the window, for the tests. Nil: no record.
    @ObservationIgnored var leafCalls: [String]?
    /// The work of the last transport or speed key, for `settleTransport()`.
    @ObservationIgnored var transportWork: Task<Void, Never>?
    /// The lanes of the window, for the zoom commands.
    @ObservationIgnored weak var timelineView: TimelineScrollView?
    /// The zoom history and the toggles of the window (decision 0025). The window owns it, so a
    /// new pane from SwiftUI keeps it, and `timeline.canGoBack` never describes an old pane.
    @ObservationIgnored var navigation = Navigation()
    /// The last view of the lanes. A new pane shows it, so the pane makes no zoom with no entry.
    @ObservationIgnored var shownZoom: Zoom?
    @ObservationIgnored var opening: Task<Void, Never>?
    /// Tests give their own list.
    @ObservationIgnored var deviceList = DeviceList.shared
    /// The running apps of the Apps section of the route menu (A15), and the name of each app
    /// that a list had. `refreshApps` reads them off the main actor.
    var apps: [RunningApp] = []
    @ObservationIgnored var appNames: [String: String] = [:]
    /// Tests give their own list.
    @ObservationIgnored var readApps: @Sendable () -> [RunningApp] = { RunningApp.all() }
    /// The name of an app that does not run, from its bundle. Tests give their own.
    @ObservationIgnored var readAppName: @Sendable (String) -> String = { DirigibleAudio.appName($0) }
    /// False on macOS 14.0 and 14.1 (A14). Tests set it.
    @ObservationIgnored var tapsAvailable = processTapsAvailable
    /// The macOS microphone prompt (decision 0013). Tests give their own.
    @ObservationIgnored var requestMicrophoneAccess: () async -> Bool = {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    init(url: URL, recordings: ActiveRecordings?, app: AppDelegate) {
        self.url = url
        self.recordings = recordings
        self.app = app
        silences = SilenceState(defaults: app.defaults)
        leadingPane = LeadingPaneState(defaults: app.defaults)
        showsLoudness = app.defaults?.object(forKey: Self.loudnessKey) as? Bool ?? true
        showsInspector = app.defaults?.bool(forKey: Self.inspectorKey) ?? false
        inspectorWidth = InspectorWidth(stored: app.defaults?.object(forKey: InspectorWidth.defaultsKey))
        headerWidth = HeaderWidth(stored: app.defaults?.object(forKey: HeaderWidth.defaultsKey))
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
        // No window tabs, so no File > New Tab item takes Command-T (decision 0040).
        window.tabbingMode = .disallowed
        window.delegate = self
        self.window = window
        chrome = SessionChrome(model: self, window: window)
        showTitle()
        window.placeAsSessionWindow(after: previous)
        window.makeKeyAndOrderFront(nil)
        app?.noticeWindowShown(window)
    }

    func bringToFront() { window?.makeKeyAndOrderFront(nil) }

    /// Opens the package off the main actor (`Studio.open` runs the recovery).
    func open(recovering: Bool) {
        self.recovering = recovering
        phase = .opening
        opening = Task {
            do throws(StudioError) {
                let studio = try await Studio.open(
                    url, recordings: recordings, peakCache: app?.peakCache, log: app?.log ?? .disabled)
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

    /// Shows an open studio: each routed track arms, except a track that takes a channel of an
    /// earlier armed track (`tracksToArm`). The window follows `Studio.url`.
    /// The studio gets the studios of the other windows: a take ends their exports (decision 0019).
    func adopt(_ studio: Studio) {
        armed = Set(tracksToArm(studio.session.tracks))
        studio.otherStudios = { [weak app, weak studio] in
            app?.windows.values.compactMap(\.studio).filter { $0 !== studio } ?? []
        }
        phase = .open(studio)
        follow(studio)
        followMonitor(studio)
        followActivation()
        followTakeError(studio)
    }

    func refreshPendingSpace() async {
        pendingSpace = await idleStudio?.pendingSpace()
    }

    /// Drops the studio, so its lock goes, and breaks the cycle of the window and its view.
    func finishClose() {
        phase = .closed
        activeObserver.map(NotificationCenter.default.removeObserver)
        activeObserver = nil
        // The pool releases the view now, not at the end of the main-queue job, so the studio
        // and its lock go before this call returns, and an open right after it works.
        autoreleasepool {
            let window = window
            app?.noticeWindowClosed(window)
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
}
