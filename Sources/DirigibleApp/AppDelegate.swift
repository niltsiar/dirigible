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
    /// The packages of the list at launch that exist, read once off the main actor (decision
    /// 0004).
    @ObservationIgnored let listedAtLaunch: Task<Set<URL>, Never>
    /// The open events whose windows are not in the registry yet. The launch shows the Open
    /// panel only when none waits.
    @ObservationIgnored private var openEvents = 0

    /// The app: the list of active recordings in Application Support.
    override convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(
            recordings: ActiveRecordings(
                file: support.appending(path: "com.delineas.dirigible/active-recordings.plist")))
    }

    init(recordings: ActiveRecordings?) {
        self.recordings = recordings
        listedAtLaunch = Task.detached {
            Set(
                (recordings?.packages() ?? []).map(packageIdentity).filter {
                    FileManager.default.fileExists(atPath: $0.path)
                })
        }
    }

    /// Brings the window of the package to the front, or makes one. The identity reads the file
    /// system (symbolic links), so it resolves off the main actor.
    @discardableResult func open(_ url: URL) async -> SessionWindow {
        let key = await identity(of: url)
        if let existing = windows[key] {
            existing.bringToFront()
            return existing
        }
        let window = SessionWindow(url: key, recordings: recordings, app: self)
        // Before the open, so a Quit sees the window.
        windows[key] = window
        window.show()
        let listed = listedAtLaunch
        Task { window.open(recovering: await listed.value.contains(key)) }
        NSDocumentController.shared.noteNewRecentDocumentURL(key)
        recent = NSDocumentController.shared.recentDocumentURLs
        return window
    }

    /// A write found the package moved on its volume.
    func rekey(_ old: URL, to new: URL) {
        guard let window = windows.removeValue(forKey: old) else { return }
        windows[new] = window
    }

    /// By identity: a move can change the key.
    func forget(_ closed: SessionWindow) {
        windows = windows.filter { $0.value !== closed }
        if key === closed { key = nil }
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

    /// A new package at 48 kHz. `Session.create` refuses a path that exists, so the "Replace"
    /// answer of the panel gives the `.exists` alert, and the item on disk does not change.
    func newSession() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.sessionType]
        panel.nameFieldStringValue = L10n.panelNewName.text
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let created = await Task.detached { () -> SessionFileError? in
                    do throws(SessionFileError) { try Session.create(at: url, sampleRate: 48_000) } catch {
                        return error
                    }
                    return nil
                }.value
                if let created {
                    self?.showError(.file(created))
                } else {
                    await self?.open(url)
                }
            }
        }
    }

    private func showError(_ error: StudioError) {
        let alert = NSAlert()
        alert.messageText = L10n.message(for: error)
        alert.runModal()
    }

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
