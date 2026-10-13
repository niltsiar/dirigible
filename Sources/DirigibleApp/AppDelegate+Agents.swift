import AppKit
import DirigibleAudio
import DirigibleMCP

/// The agent server of the app (decision 0046): the Settings switch and the windows that an
/// agent call can reach.
extension AppDelegate {
    static let agentsKey = "agents.edit.open.sessions"

    /// The Settings switch. Off when no value is stored (C1).
    var agentsOn: Bool { defaults?.bool(forKey: Self.agentsKey) ?? false }

    /// Stores the switch, and starts or stops the server.
    func setAgents(_ on: Bool) {
        defaults?.set(on, forKey: Self.agentsKey)
        if on { agents.start() } else { agents.stop() }
    }

    /// At launch, and after a cancelled Quit.
    func startAgentsIfOn() {
        if agentsOn { agents.start() }
    }

    /// Each window with a studio. A window refuses agent edits (C4) while it is not open, while a
    /// lane drag runs (an edit then cannot join the drag's undo step), while a record request
    /// waits or starts (decision 0048), and during a Quit. `record` shows the consent sheet.
    func agentTargets() -> [AgentTarget] {
        windows.values.compactMap { window in
            guard let studio = window.studio else { return nil }
            let open = if case .open = window.phase { true } else { false }
            let dragging = window.timelineView?.gesture.isActive == true
            let busy: AgentBusy? =
                if terminating {
                    .quit
                } else if !open {
                    .closing
                } else if window.consent != nil {
                    .asking
                } else if dragging {
                    .drag
                } else {
                    nil
                }
            return AgentTarget(studio: studio, busy: busy) { [weak window] request, agent in
                await window?.askRecord(request, agent: agent) ?? .closed
            }
        }
    }
}
