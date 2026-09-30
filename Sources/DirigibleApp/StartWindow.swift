import AppKit
import SwiftUI

/// The start window (decision 0027) and its `NSWindowDelegate`. `AppDelegate` owns it while it
/// shows. It is a plain `NSWindow`, not an `UndoRoutingWindow`, so a plain key goes to its text
/// and never to a transport. It is not restorable, and a close drops it.
@MainActor final class StartWindow: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private weak var app: AppDelegate?

    init(app: AppDelegate) {
        self.app = app
        super.init()
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: StartView { [weak app] in app?.showOpenPanel() }))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = L10n.startTitle.text
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
    }

    func show() { window?.makeKeyAndOrderFront(nil) }

    /// Through `NSWindow.close()`, so `windowWillClose(_:)` runs.
    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        app?.startDidClose()
    }
}
