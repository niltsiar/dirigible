import AppKit

extension AppDelegate {
    /// During a take, one question. A refused episode draft stops Quit, as it stops Close. Then every
    /// window settles; a window whose last save still failed gives one more question.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        beginQuit()
        guard !windows.isEmpty else { return .terminateNow }
        if windows.values.contains(where: \.isTakeRunning),
            !confirmQuit(L10n.alertQuitRecording.text, L10n.alertQuitRecordingConfirm.text, false)
        {
            cancelQuit()
            return .terminateCancel
        }
        if let held = windows.values.first(where: { $0.holdsRefusedEpisode() }) {
            cancelQuit()
            held.window?.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
        // After the cancel gates and before the settle: no agent edit can come after its window
        // settles (decision 0046).
        agents.stop()
        let open = Array(windows.values)
        Task {
            for window in open { await window.settle() }
            let failed = open.filter { $0.studio?.saveError != nil }.map {
                $0.url.deletingPathExtension().lastPathComponent
            }
            let names = failed.joined(separator: ", ")
            let quit =
                failed.isEmpty
                || confirmQuit(L10n.alertQuitUnsaved.format(names), L10n.alertQuitUnsavedConfirm.text, true)
            // A cancelled Quit: the settle started no peak pass (decision 0017).
            if !quit {
                cancelQuit()
                for window in open { window.studio?.loadPeaks() }
                startAgentsIfOn()
            }
            replyToTerminate(quit)
        }
        return .terminateLater
    }
}

/// A Quit question: the action button, then Cancel with Esc in each language (NSAlert gives Esc
/// only to the title "Cancel"). Stop and Quit takes Return. After a failed save, Quit takes no
/// Return: one key must not drop edits that Undo cannot give back (decision 0014).
@MainActor func quitQuestion(_ message: String, button: String, unsaved: Bool) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = message
    let action = alert.addButton(withTitle: button)
    alert.addButton(withTitle: L10n.alertCancel.text).keyEquivalent = "\u{1b}"
    if unsaved {
        action.keyEquivalent = ""
        action.hasDestructiveAction = true
    }
    return alert
}
