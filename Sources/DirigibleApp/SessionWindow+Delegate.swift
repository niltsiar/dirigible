import AppKit
import DirigibleAudio

extension SessionWindow: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose()
        return false
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

    /// A focus reads the device list again, so a channel change of a present device shows, and
    /// checks the media, so a file that the user put back shows (decision 0016). It loads the
    /// peaks again, because a WAV can change outside the app (decision 0017).
    func windowDidBecomeKey(_ notification: Notification) {
        app?.key = self
        chrome?.refreshRecordTime()
        deviceList.changed()
        refreshApps()
        if case .open(let studio) = phase { studio.loadPeaks() }
        Task { await idleStudio?.checkMedia() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if app?.key === self { app?.key = nil }
    }
}
