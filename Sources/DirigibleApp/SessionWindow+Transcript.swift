import AppKit
import DirigibleAudio
import DirigibleCore
import Observation

/// The state of the Transcript pane that the window keeps (decision 0023).
@Observable @MainActor final class TranscriptFollow {
    /// True from View > Show Transcript until the pane has the focus. The pane may not exist yet.
    var focusRequest = false
    /// The counts banner of the last Import Transcript.
    var importReport: TranscriptImportShown?
    @ObservationIgnored var importPresses = 0
    /// True while the pane keeps the current unit about one third from the top (P4, P18).
    var isOn = true
    /// The top of the visible text when the pane left the window, for the next pane (P4).
    @ObservationIgnored var scrollOrigin: Double?
    /// The pane that shows, held weakly so a removed pane and its text are freed (P4).
    @ObservationIgnored weak var pane: TranscriptTextView?
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

    /// The display tick: marks the units that hold `frame` in the pane, when it shows (P4).
    func transcriptTick(frame: Frames) { transcriptFollow.pane?.highlight(frame: frame) }

    /// The Follow Playhead toggle and View item (P18).
    func toggleTranscriptFollow() {
        transcriptFollow.isOn.toggle()
        if transcriptFollow.isOn { transcriptFollow.pane?.scrollToCurrent() }
    }

    /// A play start or a seek turns the follow on (P4).
    func resumeTranscriptFollow() {
        guard !transcriptFollow.isOn else { return }
        toggleTranscriptFollow()
    }

    /// True for a command that seeks, or that starts a play from a stopped play.
    func startsOrSeeks(_ command: TransportCommand) -> Bool {
        switch command {
        case .seek: true
        case .pause, .stopAndReturn: false
        case .playStop, .forward, .reverse, .slowForward, .slowReverse: studio?.playback == .stopped
        }
    }

    /// The View item: Hide Transcript hides the inspector while the Transcript tab shows.
    func toggleTranscript() {
        if showsInspector, inspectorTab == .transcript { toggleInspector() } else { showTranscript() }
    }
}

extension AppDelegate {
    /// The check mark and the state of View > Follow Playhead in Transcript for the key window.
    var transcriptFollowItem: (checked: Bool, enabled: Bool) {
        let shown = key?.showsInspector == true && key?.inspectorTab == .transcript
        return (key?.transcriptFollow.isOn == true, shown)
    }

    /// The title and the state of View > Show/Hide Transcript for the key window.
    var transcriptItem: (title: L10n, enabled: Bool) { transcriptItem(for: key) }

    func transcriptItem(for model: SessionWindow?) -> (title: L10n, enabled: Bool) {
        let shown = model?.showsInspector == true && model?.inspectorTab == .transcript
        return (shown ? .menuViewTranscriptHide : .menuViewTranscriptShow, model?.studio != nil)
    }
}
