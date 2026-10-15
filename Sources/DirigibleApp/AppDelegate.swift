import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Observation
import UniformTypeIdentifiers

/// The registry of session windows: one window per package, keyed by `packageIdentity`
/// (decision 0014). Finder, Open, Open Recent, and the launch reopen all come to `open`.
@Observable @MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var windows: [URL: SessionWindow] = [:]
    /// The one Copy and Cut of the app (decision 0042): in memory, not on `NSPasteboard`. A window
    /// close keeps it; a quit drops it.
    @ObservationIgnored var clipboard: Clipboard?
    /// The window whose `NSWindow` is key. The commands act on it.
    var key: SessionWindow?
    /// The recent sessions, the newest first: the start window and File > Open Recent read it. The
    /// app preferences keep it as absolute paths (decision 0027). The list of
    /// `NSDocumentController` belongs to one code signature, and each ad-hoc build has a new one.
    var recent: [URL]
    static let recentKey = "recent.sessions"
    static let recentLimit = 10
    /// The folder of new sessions that the user chose with Change…, a `String` absolute path.
    static let folderKey = "session.folder"
    /// View > Snap (snap run): one value for all windows, kept in the app preferences. On when
    /// no value is stored.
    var snaps: Bool { didSet { defaults?.set(snaps, forKey: Self.snapKey) } }
    static let snapKey = "timeline.snaps"
    /// The speed that Period turns on (decision 0052): the last speed other than 1.
    var lastSpeed: Speed { didSet { defaults?.set(lastSpeed.factor, forKey: Self.speedKey) } }
    static let speedKey = "playback.lastSpeed"

    @ObservationIgnored let recordings: ActiveRecordings?
    /// The peak cache folder of every studio (decision 0017). Nil: no peaks (tests).
    @ObservationIgnored let peakCache: URL?
    /// The app preferences that a session window reads at open and writes (the header width).
    /// The Settings language pick writes `AppleLanguages` here too, so the app passes `.standard`:
    /// the runtime reads the language from the app domain at launch, never from a suite.
    /// Nil: the defaults of each value and no writes (tests, learning 4475c89).
    @ObservationIgnored let defaults: UserDefaults?
    /// The packages of the list at launch that exist, read once off the main actor (decision
    /// 0004).
    @ObservationIgnored let listedAtLaunch: Task<Set<URL>, Never>
    /// The folder of new sessions when the user chose none (decision 0027). Nil: no start
    /// window (tests).
    @ObservationIgnored let defaultFolder: URL?
    /// The start window while it shows (decision 0027). A close sets it to nil.
    @ObservationIgnored private(set) var start: StartWindow?
    /// True from the Quit decision until a cancel: no start window shows (decision 0027), and
    /// each agent edit is refused (decision 0046).
    @ObservationIgnored private(set) var terminating = false
    /// Sets the Dock badge (decision 0050). Tests give their own.
    @ObservationIgnored var dockBadge: @MainActor (String?) -> Void = { NSApp.dockTile.badgeLabel = $0 }
    /// The socket of the agent server. Tests give a short path of their own.
    @ObservationIgnored let agentSocket: URL
    /// The agent server (decision 0046). The Settings switch starts and stops it.
    @ObservationIgnored private(set) lazy var agents = AgentServer(socket: agentSocket) { [weak self] in
        self?.agentTargets() ?? []
    }
    /// Tests replace the Quit question (message, button, true after a failed save; true for the button)
    /// and the answer to `.terminateLater`, so no alert shows and the test process does not quit.
    @ObservationIgnored var confirmQuit: @MainActor (String, String, Bool) -> Bool = { message, button, unsaved in
        quitQuestion(message, button: button, unsaved: unsaved).runModal() == .alertFirstButtonReturn
    }
    @ObservationIgnored var replyToTerminate: @MainActor (Bool) -> Void = {
        NSApp.reply(toApplicationShouldTerminate: $0)
    }
    /// The open events whose windows are not in the registry yet. The launch shows the start
    /// window only when none waits.
    @ObservationIgnored private var openEvents = 0
    /// The J and L hold of the key monitor (decision 0016).
    @ObservationIgnored private var hold = ShuttleHold<Studio>()
    @ObservationIgnored private var keyMonitor: Any?
    /// Shows files in Finder. Tests give their own.
    @ObservationIgnored var reveal: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    /// Opens a file in its default app. Tests give their own.
    @ObservationIgnored var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The first free name of a new session, "Episode 2" for 2. Tests give their own: in the test
    /// process, `L10n` gives the key.
    @ObservationIgnored var nameFormat: @Sendable (Int) -> String = { L10n.startNameDefault.format($0) }
    /// The file checks of the start window, off the main actor. Tests give their own.
    @ObservationIgnored var exists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    /// The folder panel of Change…, as a sheet of the start window, and the answer. Tests give
    /// their own.
    @ObservationIgnored var chooseFolder: (NSWindow, @escaping @MainActor (URL?) -> Void) -> Void = { window, done in
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.startFolderChoose.text
        panel.beginSheetModal(for: window) { done($0 == .OK ? panel.url : nil) }
    }
    /// The alert of a failed Create. Tests give their own: `runModal()` blocks.
    @ObservationIgnored var showError: @MainActor (StudioError) -> Void = { error in
        let alert = NSAlert()
        alert.messageText = L10n.message(for: error)
        alert.runModal()
    }
    /// The files that the import takes: WAV, AIFF, FLAC, MP3, and M4A (decision 0040). The open
    /// panel and a drop on the lanes read them.
    static let importTypes: [UTType] =
        [.wav, .aiff, .mp3, .mpeg4Audio] + [UTType(filenameExtension: "flac")].compactMap { $0 }
    /// The open panel of File > Import Audio… as a sheet of a window: one file of `importTypes`.
    /// Tests give their own.
    @ObservationIgnored var chooseImport: (NSWindow, @escaping @MainActor (URL?) -> Void) -> Void = { window, done in
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppDelegate.importTypes
        panel.beginSheetModal(for: window) { done($0 == .OK ? panel.url : nil) }
    }
    /// The save panel of Export as a sheet of a window: the name, the session rate, the
    /// settings of the pop-ups, the note of unheard tracks, and the answer. Tests give their own.
    @ObservationIgnored var chooseExport:
        (NSWindow, String, Int, ExportSettings, String?, @escaping @MainActor (ExportTarget?) -> Void) -> Void = {
            ExportPanel.begin(for: $0, name: $1, sessionRate: $2, settings: $3, note: $4, done: $5)
        }
    /// The save panel of Export Chapters as a sheet of a window: the name, the message, and the
    /// answer. Tests give their own.
    @ObservationIgnored var chooseChaptersExport:
        (NSWindow, String, String?, @escaping @MainActor (ChaptersTarget?) -> Void) -> Void = {
            ExportPanel.beginChapters(for: $0, name: $1, message: $2, done: $3)
        }

    /// The app: the list of active recordings in Application Support.
    override convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(
            recordings: ActiveRecordings(
                file: support.appending(path: "com.delineas.dirigible/active-recordings.plist")),
            peakCache: PeakFile.folder, defaults: .standard,
            defaultFolder: FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
                .appending(path: "Dirigible", directoryHint: .isDirectory))
    }

    init(
        recordings: ActiveRecordings?, peakCache: URL? = nil, defaults: UserDefaults? = nil, defaultFolder: URL? = nil,
        agentSocket: URL = agentSocketPath()
    ) {
        self.recordings = recordings
        self.agentSocket = agentSocket
        self.defaultFolder = defaultFolder
        self.peakCache = peakCache
        self.defaults = defaults
        snaps = defaults?.object(forKey: Self.snapKey) as? Bool ?? true
        lastSpeed = Self.lastSpeed(stored: defaults?.object(forKey: Self.speedKey))
        // Only absolute paths, as for the folder preference. The hint reads no file.
        recent = (defaults?.stringArray(forKey: Self.recentKey) ?? []).filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let peakCache {
            // A cache file that no pass used for 90 days goes (decision 0017).
            Task.detached(priority: .background) {
                PeakFile.prune(peakCache, before: .now.addingTimeInterval(-PeakFile.unusedLimit))
            }
        }
        listedAtLaunch = Task.detached {
            Set(
                (recordings?.packages() ?? []).map(packageIdentity).filter {
                    FileManager.default.fileExists(atPath: $0.path)
                })
        }
    }

    /// Brings the window of the package to the front, or makes one. The identity reads the file
    /// system (symbolic links), so it resolves off the main actor. `created` is the studio of
    /// New Session, which is open already.
    @discardableResult func open(_ url: URL, created: Studio? = nil) async -> SessionWindow {
        let key: URL
        if let created { key = created.url } else { key = await identity(of: url) }
        // Before the early return: an open of an open session closes it too (plan gate, item 6).
        start?.close()
        if let existing = windows[key] {
            existing.bringToFront()
            return existing
        }
        let window = SessionWindow(url: key, recordings: recordings, app: self)
        // Before the open, so a Quit sees the window.
        windows[key] = window
        window.show()
        if let created {
            window.adopt(created)
        } else {
            let listed = listedAtLaunch
            Task { window.open(recovering: await listed.value.contains(key)) }
        }
        // The Dock menu and Apple menu > Recent Items read the system list.
        NSDocumentController.shared.noteNewRecentDocumentURL(key)
        // By path: two URLs of one package can differ in the trailing slash.
        recent = Array(([key] + recent.filter { $0.path != key.path }).prefix(Self.recentLimit))
        defaults?.set(recent.map(\.path), forKey: Self.recentKey)
        return window
    }

    /// A write found the package of `window` moved on its volume. The entry of another window
    /// stays: its key can be stale until its next write (decision 0014). Then `window` keeps
    /// its old key, and both windows stay in the registry. The recent list gets the new path in
    /// place of the old path (code gate 1, item 2).
    func rekey(_ window: SessionWindow, to new: URL) {
        guard windows[new] == nil, let old = windows.first(where: { $0.value === window })?.key else { return }
        windows[old] = nil
        windows[new] = window
        NSDocumentController.shared.noteNewRecentDocumentURL(new)
        // By path, as in `open`. A stale row at the new path goes, so no path shows two times.
        recent = recent.filter { $0.path != new.path }.map { $0.path == old.path ? new : $0 }
        defaults?.set(recent.map(\.path), forKey: Self.recentKey)
    }

    /// File > Open Recent > Clear Menu: empties the app list, its preference, the rows of the
    /// start window, and the system list of the Dock menu (code gate 1, item 3). The app never
    /// drops a path by itself: a denied path is not a missing path.
    func clearRecent() {
        recent = []
        defaults?.set(recent.map(\.path), forKey: Self.recentKey)
        NSDocumentController.shared.clearRecentDocuments(nil)
        start?.model.loadRows()
    }

    /// By identity: a move can change the key.
    func forget(_ closed: SessionWindow) {
        windows = windows.filter { $0.value !== closed }
        if key === closed { key = nil }
        if windows.isEmpty { showStart() }
    }

    /// Drops the auto-repeat of J, L, and Space, and pauses at the key-up of a hold (probe H1). The
    /// release calls the pause directly, with no key forward (plan gate 2 item 6), on the Studio
    /// of the key-down, also when the key window changed during the hold.
    private func watchKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            let target = takesTransportKeys(NSApp.keyWindow) ? key?.studio : nil
            switch hold.handle(event, target: target) {
            case .drop: return nil
            case .release(let studio): Task { await studio.perform(.pause) }
            case .pass: break
            }
            return event
        }
    }

    // MARK: Start window

    /// The one path of every trigger (decision 0027), also Window > Start Window with a session
    /// window open: a new window when none shows, else the open one to the front. A `focus` moves
    /// the focus there, and a later result keeps it.
    func showStart(focus: StartField? = nil) {
        guard let defaultFolder, !terminating else { return }
        if start == nil { start = StartWindow(app: self, folder: sessionFolder ?? defaultFolder) }
        if let focus { start?.model.pin(focus) }
        start?.model.loadRows()
        start?.show()
    }

    /// The folder of new sessions that the user chose (Change…), only as an absolute path
    /// (plan gate, item 5). The key never changes its meaning or its type (decision 0027).
    private var sessionFolder: URL? {
        guard let path = defaults?.string(forKey: Self.folderKey), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The `windowWillClose(_:)` of the start window.
    func startDidClose() { start = nil }

    // MARK: Panels

    private static let sessionType = UTType(filenameExtension: "dirigible", conformingTo: .package) ?? .package

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.sessionType]
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in for url in urls { await self?.open(url) } }
        }
    }

    /// File > New Session: the start window with the focus in the name field (decision 0027).
    func newSession() { showStart(focus: .name) }

    /// Makes the package with `Studio.create` and shows it in a window. Returns the error.
    func createSession(at url: URL) async -> StudioError? {
        do throws(StudioError) {
            await open(
                url,
                created: try await Studio.create(
                    url, sampleRate: 48_000, recordings: recordings, peakCache: peakCache))
        } catch {
            return error
        }
        return nil
    }

    // MARK: Help

    /// The user guide page that `scripts/bundle.sh` makes from `docs/guide.md`. It is English only.
    nonisolated static func guideURL(in bundle: Bundle) -> URL {
        bundle.bundleURL.appending(path: "Contents/Resources/Guide/guide.html")
    }

    /// Help > Dirigible Guide.
    func openGuide() { openURL(Self.guideURL(in: .main)) }

    // MARK: NSApplicationDelegate

    func application(_ application: NSApplication, open urls: [URL]) {
        openEvents += 1
        Task {
            for url in urls { await open(url) }
            openEvents -= 1
        }
    }

    /// Open events come before this call (probe P7).
    func applicationDidFinishLaunching(_ notification: Notification) {
        watchKeys()
        watchNotices()
        startAgentsIfOn()
        Task { await openAtLaunch() }
    }

    /// The packages of the list open; with no window and no open event that waits, the start
    /// window shows.
    func openAtLaunch() async {
        for url in await listedAtLaunch.value.sorted(by: { $0.path < $1.path }) { await open(url) }
        if windows.isEmpty && openEvents == 0 { showStart() }
    }

    /// A Dock click.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if windows.isEmpty { showStart() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Marks the Quit decision (`terminating` is true until `cancelQuit`).
    func beginQuit() { terminating = true }

    /// Ends `terminating` after a Quit that a question, a refused draft, or a failed save cancelled.
    func cancelQuit() { terminating = false }
}

/// `packageIdentity` off the main actor.
@concurrent nonisolated func identity(of url: URL) async -> URL {
    dispatchPrecondition(condition: .notOnQueue(.main))
    return packageIdentity(url)
}
