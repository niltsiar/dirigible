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

    @ObservationIgnored private let recordings: ActiveRecordings?
    /// The registry: a move changes the key, and a close removes the entry.
    @ObservationIgnored private weak var app: AppDelegate?
    @ObservationIgnored private(set) var window: NSWindow?
    @ObservationIgnored private var opening: Task<Void, Never>?

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
        let window = NSWindow(contentViewController: NSHostingController(rootView: SessionView(model: self)))
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
                phase = .open(studio)
                follow(studio)
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

    /// Drops the studio, so its lock goes, and breaks the cycle of the window and its view.
    private func finishClose() {
        phase = .closed
        let window = window
        self.window = nil
        window?.close()
        window?.contentViewController = nil
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

    func windowDidBecomeKey(_ notification: Notification) { app?.key = self }

    func windowDidResignKey(_ notification: Notification) {
        if app?.key === self { app?.key = nil }
    }
}
