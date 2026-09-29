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
    private(set) var recent: [URL] = NSDocumentController.shared.recentDocumentURLs

    @ObservationIgnored let recordings: ActiveRecordings?
    /// The peak cache folder of every studio (decision 0017). Nil: no peaks (tests).
    @ObservationIgnored let peakCache: URL?
    /// The app preferences that a session window reads at open and writes (the header width).
    /// Nil: the defaults of each value and no writes (tests, learning 4475c89).
    @ObservationIgnored let defaults: UserDefaults?
    /// The packages of the list at launch that exist, read once off the main actor (decision
    /// 0004).
    @ObservationIgnored let listedAtLaunch: Task<Set<URL>, Never>
    /// The open events whose windows are not in the registry yet. The launch shows the Open
    /// panel only when none waits.
    @ObservationIgnored private var openEvents = 0
    /// The J and L hold of the key monitor (decision 0016).
    @ObservationIgnored private var hold = ShuttleHold<Studio>()
    @ObservationIgnored private var keyMonitor: Any?
    /// Shows files in Finder. Tests give their own.
    @ObservationIgnored var reveal: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    /// Opens a web page in the browser. Tests give their own.
    @ObservationIgnored var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The save panel of Export as a sheet of a window: the name, the session rate, and the
    /// answer. Tests give their own.
    @ObservationIgnored var chooseExport:
        (NSWindow, String, Int, @escaping @MainActor (ExportTarget?) -> Void) -> Void = {
            ExportPanel.begin(
                for: $0, name: $1, sessionRate: $2, settings: ExportSettings(defaults: .standard), done: $3)
        }

    /// The app: the list of active recordings in Application Support.
    override convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(
            recordings: ActiveRecordings(
                file: support.appending(path: "com.delineas.dirigible/active-recordings.plist")),
            peakCache: PeakFile.folder, defaults: .standard)
    }

    init(recordings: ActiveRecordings?, peakCache: URL? = nil, defaults: UserDefaults? = nil) {
        self.recordings = recordings
        self.peakCache = peakCache
        self.defaults = defaults
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
        NSDocumentController.shared.noteNewRecentDocumentURL(key)
        recent = NSDocumentController.shared.recentDocumentURLs
        return window
    }

    /// A write found the package of `window` moved on its volume. The entry of another window
    /// stays: its key can be stale until its next write (decision 0014). Then `window` keeps
    /// its old key, and both windows stay in the registry.
    func rekey(_ window: SessionWindow, to new: URL) {
        guard windows[new] == nil, let old = windows.first(where: { $0.value === window })?.key else { return }
        windows[old] = nil
        windows[new] = window
    }

    /// By identity: a move can change the key.
    func forget(_ closed: SessionWindow) {
        windows = windows.filter { $0.value !== closed }
        if key === closed { key = nil }
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

    /// A new package at 48 kHz. `Studio.create` refuses a path that exists, so the "Replace"
    /// answer of the panel gives the `.exists` alert, and the item on disk does not change.
    func newSession() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.sessionType]
        panel.nameFieldStringValue = L10n.panelNewName.text
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if let error = await self?.createSession(at: url) { self?.showError(error) }
            }
        }
    }

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

    private func showError(_ error: StudioError) {
        let alert = NSAlert()
        alert.messageText = L10n.message(for: error)
        alert.runModal()
    }

    // MARK: Help

    /// The user guide on GitHub. A fork keeps this URL.
    static let guideURL = URL(string: "https://github.com/niltsiar/dirigible/blob/main/docs/guide.md")!

    /// Help > Dirigible Guide.
    func openGuide() { openURL(Self.guideURL) }

    // MARK: NSApplicationDelegate

    func application(_ application: NSApplication, open urls: [URL]) {
        openEvents += 1
        Task {
            for url in urls { await open(url) }
            openEvents -= 1
        }
    }

    /// Open events come before this call (probe P7). The packages of the list open next; with no
    /// window, the Open panel shows.
    func applicationDidFinishLaunching(_ notification: Notification) {
        watchKeys()
        let listed = listedAtLaunch
        Task {
            for url in await listed.value.sorted(by: { $0.path < $1.path }) { await open(url) }
            if windows.isEmpty && openEvents == 0 { showOpenPanel() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if windows.isEmpty { showOpenPanel() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// During a take, one question. Then every window settles; a window whose last save still
    /// failed gives one more question.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !windows.isEmpty else { return .terminateNow }
        if windows.values.contains(where: \.isTakeRunning),
            !confirm(L10n.alertQuitRecording.text, button: L10n.alertQuitRecordingConfirm.text)
        {
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
            if !quit { for window in open { window.studio?.loadPeaks() } }
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
