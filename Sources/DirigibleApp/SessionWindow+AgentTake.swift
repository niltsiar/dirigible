import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleMCP

/// The notice of an agent take (decision 0050): the take row, the VoiceOver announcement, the
/// Dock bounce and badge.
extension SessionWindow {
    /// An agent take started: the row and the badge show it until the transport leaves it.
    func agentTakeStarted(_ consent: ConsentRequest, take: Int, byGrant: Bool) {
        guard let studio else { return }
        let started = AgentTake(
            take: take, agent: consent.agent.name, tracks: consent.names, seconds: consent.seconds,
            since: studio.recordingSince ?? .now, byGrant: byGrant, connection: consent.connection)
        agentRecord.take = started
        followAgentTake(studio, take: take)
        if !attention.isActive() { attention.inform() }
        chrome?.announce(agentTakeText(started), .high)
        app?.updateAgentBadge()
    }

    /// The text of the take row of an agent take, with the time left.
    func agentTakeText(_ take: AgentTake, now: ContinuousClock.Instant = .now) -> String {
        let elapsed: Duration = now - take.since
        let left = max(Duration.zero, Duration.seconds(take.seconds) - elapsed)
        let time = Duration.seconds(Int((left / .seconds(1)).rounded(.up))).formatted(.time(pattern: .minuteSecond))
        let tracks = ListFormatter.localizedString(byJoining: take.tracks)
        guard let agent = take.agent else { return L10n.takeAgentUnnamed.format(take.take, tracks, time) }
        return L10n.takeAgent.format(take.take, tracks, agent, time)
    }

    /// Clears the agent take when the transport leaves it.
    private func followAgentTake(_ studio: Studio, take: Int) {
        withObservationTracking {
            _ = studio.transport
        } onChange: { [weak self, weak studio] in
            Task { @MainActor in
                guard let self else { return }
                if let studio, self.studio === studio, case .recording(take) = studio.transport {
                    return self.followAgentTake(studio, take: take)
                }
                self.agentTakeEnded(take)
            }
        }
    }

    private func agentTakeEnded(_ take: Int) {
        guard agentRecord.take?.take == take else { return }
        agentRecord.take = nil
        app?.updateAgentBadge()
    }
}

extension AppDelegate {
    /// The Dock badge belongs to the app: REC while any window has an agent take (decision 0050).
    func updateAgentBadge() {
        dockBadge(windows.values.contains { $0.agentRecord.take != nil } ? L10n.dockBadgeRecording.text : nil)
    }
}
