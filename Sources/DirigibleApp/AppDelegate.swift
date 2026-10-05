import AppKit
import DirigibleAudio
import DirigibleCore
import Observation
import UniformTypeIdentifiers

/// The registry of session windows: one window per package, keyed by `packageIdentity`
/// (decision 0014). Finder, Open, Open Recent, and the launch reopen all come to `open`.
@Observable @MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var windows: [URL: SessionWindow] = [:]
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

    @ObservationIgnored let recordings: ActiveRecordings?
    /// The peak cache folder of every studio (decision 0017). Nil: no peaks (tests).
    @ObservationIgnored let peakCache: URL?
    /// The app preferences that a session window reads at open and writes (the header width).
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
    /// True from the Quit decision until a cancel: no start window shows (decision 0027).
    @ObservationIgnored private(set) var terminating = false
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
    /// The save panel of Export as a sheet of a window: the name, the session rate, the
    /// settings of the pop-ups, the note of unheard tracks, and the answer. Tests give their own.
    @ObservationIgnored var chooseExport:
        (NSWindow, String, Int, ExportSettings, String?, @escaping @MainActor (ExportTarget?) -> Void) -> Void = {
            ExportPanel.begin(for: $0, name: $1, sessionRate: $2, settings: $3, note: $4, done: $5)
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
        recordings: ActiveRecordings?, peakCache: URL? = nil, defaults: UserDefaults? = nil, defaultFolder: URL? = nil
    ) {
        self.recordings = recordings
        self.defaultFolder = defaultFolder
        self.peakCache = peakCache
        self.defaults = defaults
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

    // MARK: Transport

    /// The action of each plain-key Transport item: a key that belongs to text or to a panel
    /// goes there (probes K1, K3); else the key session window performs the command.
    func transport(_ command: TransportCommand) {
        transport(command, event: NSApp.currentEvent, in: NSApp.keyWindow)
    }

    func transport(_ command: TransportCommand, event: NSEvent?, in keyWindow: NSWindow?) {
        if let event, forwardTypingKey(event, in: keyWindow) { return }
        key?.transport(command)
    }

    /// The action of each timeline menu item. A key that a text field uses (H, I, O, Backspace,
    /// Command-B, Command-arrows) goes to text or to a panel first, as the transport keys do (probes
    /// K1, K3, E4b, E5). An item of the Edit group sends its selector from the first responder of
    /// the key window (probes E2, E3).
    func timeline(_ command: TimelineCommand) {
        timeline(command, event: NSApp.currentEvent, in: NSApp.keyWindow)
    }

    func timeline(_ command: TimelineCommand, event: NSEvent?, in keyWindow: NSWindow?) {
        if command.forwardsKey, let event, forwardTypingKey(event, in: keyWindow) { return }
        if let selector = command.selector {
            if let keyWindow { _ = (keyWindow.firstResponder ?? keyWindow).tryToPerform(selector, with: nil) }
            return
        }
        key?.run(command)
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

    /// During a take, one question. Then every window settles; a window whose last save still
    /// failed gives one more question.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminating = true
        guard !windows.isEmpty else { return .terminateNow }
        if windows.values.contains(where: \.isTakeRunning),
            !confirm(L10n.alertQuitRecording.text, button: L10n.alertQuitRecordingConfirm.text)
        {
            terminating = false
            return .terminateCancel
        }
        let open = Array(windows.values)
        Task {
            for window in open { await window.settle() }
            let failed = open.filter { $0.studio?.saveError != nil }.map {
                $0.url.deletingPathExtension().lastPathComponent
            }
            let quit =
                failed.isEmpty
                || confirm(
                    L10n.alertQuitUnsaved.format(failed.joined(separator: ", ")),
                    button: L10n.alertQuitUnsavedConfirm.text)
            // A cancelled Quit: the settle started no peak pass (decision 0017).
            if !quit {
                terminating = false
                for window in open { window.studio?.loadPeaks() }
            }
            sender.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }

    private func confirm(_ message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: L10n.alertCancel.text)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// `packageIdentity` off the main actor.
@concurrent nonisolated func identity(of url: URL) async -> URL {
    dispatchPrecondition(condition: .notOnQueue(.main))
    return packageIdentity(url)
}
