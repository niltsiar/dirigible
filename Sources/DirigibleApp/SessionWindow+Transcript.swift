import AppKit
import Observation

/// The state of the Transcript pane that the window keeps (decision 0023).
@Observable @MainActor final class TranscriptFollow {
    /// True from View > Show Transcript until the pane has the focus. The pane may not exist yet.
    var focusRequest = false
    /// The counts banner of the last Import Transcript.
    var importReport: TranscriptImportShown?
    @ObservationIgnored var importPresses = 0
}

extension SessionWindow {
    /// View > Show Transcript (P1, Shift-Command-T): shows the inspector at the Transcript tab and
    /// gives the focus to the pane. A refused Episode draft keeps the Episode tab.
    func showTranscript() {
        guard studio != nil else { return }
        selectInspectorTab(.transcript)
        guard inspectorTab == .transcript else { return }
        if !showsInspector { toggleInspector() }
        transcriptFollow.focusRequest = true
    }

    /// The View item: Hide Transcript hides the inspector while the Transcript tab shows.
    func toggleTranscript() {
        if showsInspector, inspectorTab == .transcript { toggleInspector() } else { showTranscript() }
    }
}

extension AppDelegate {
    /// The title and the state of View > Show/Hide Transcript for the key window.
    var transcriptItem: (title: L10n, enabled: Bool) { transcriptItem(for: key) }

    func transcriptItem(for model: SessionWindow?) -> (title: L10n, enabled: Bool) {
        let shown = model?.showsInspector == true && model?.inspectorTab == .transcript
        return (shown ? .menuViewTranscriptHide : .menuViewTranscriptShow, model != nil)
    }
}
