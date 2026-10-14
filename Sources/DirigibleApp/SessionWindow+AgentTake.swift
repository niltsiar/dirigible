import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import os

private let agentLog = Logger(subsystem: "com.delineas.dirigible", category: "agent-log")

/// The notice of an agent take (decision 0050): the take row, the VoiceOver announcement, the
/// Dock bounce and badge.
extension SessionWindow {
    /// An agent take started: the row and the badge show it until the transport leaves it. A take
    /// that ended before this call gets no notice.
    func agentTakeStarted(_ consent: ConsentRequest, take: Int) {
        guard let studio, case .recording(take) = studio.transport else { return }
        let started = AgentTake(
            take: take, agent: consent.agent.name, tracks: consent.names, seconds: consent.seconds,
            since: studio.recordingSince ?? .now)
        agentRecord.take = started
        let text = agentTakeText(started)
        if !attention.isActive() {
            attention.inform()
            let info = [AgentTakeNotice.idKey: started.noticeID]
            notice.post(started.noticeID, url.deletingPathExtension().lastPathComponent, text, info)
        }
        chrome?.announce(text, .high)
        app?.updateAgentBadge()
        followAgentTake(studio, take: take)
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

    /// Clears the agent take when the transport leaves it, also when it left it before the call.
    private func followAgentTake(_ studio: Studio, take: Int) {
        guard self.studio === studio, case .recording(take) = studio.transport else { return agentTakeEnded(take) }
        withObservationTracking {
            _ = studio.transport
        } onChange: { [weak self, weak studio] in
            Task { @MainActor in
                guard let self else { return }
                guard let studio else { return self.agentTakeEnded(take) }
                self.followAgentTake(studio, take: take)
            }
        }
    }

    /// Appends the end of each agent request to the agent log of the package (C16). The URL comes
    /// from the studio at each end, so a rename moves the log. A closed window writes no line.
    func logAgentEnd(_ request: RecordRequest, agent: AgentName, connection: AgentConnection?, _ answer: RecordAnswer) {
        guard let studio else { return }
        var (event, take, reason): (AgentLog.Event, Int?, String?) = (.refused, nil, nil)
        switch answer {
        case .started(let number, _, _, let grant): (event, take) = (grant?.noSheet == true ? .grant : .click, number)
        case .declined: event = .declined
        case .noAnswer: event = .noAnswer
        case .ended: reason = "ended"
        case .closed: reason = "closed"
        case .minimized: reason = "minimized"
        case .busy(let busy): reason = "busy \(busy)"
        case .refused(let error): reason = "error \(error)"
        case .grantChanged: reason = "route changed"
        case .noRoom(let minutes): reason = "no room \(minutes) min"
        case .tooMany: reason = "too many"
        }
        let entry = AgentLog.Entry(
            time: .now, event: event, take: take, agent: agent.name, connection: connection?.serial,
            tracks: request.armed.map { studio.session.track($0)?.name ?? $0.rawValue }, seconds: request.seconds,
            reason: reason)
        AgentLogWriter.append(entry, to: studio.url, holding: studio) { result in
            if result != .written {
                agentLog.error("No agent log line: \(String(describing: result), privacy: .public)")
            }
        }
    }

    /// Stop of the notification `id`: it stops only that agent take, while it records.
    func stopAgentTake(_ id: String) async {
        guard let take = agentRecord.take, take.noticeID == id, studio?.transport == .recording(take: take.take)
        else { return }
        await stop()
    }

    /// A turn-on of the grant checkbox asks for the notification permission (C14). The system
    /// shows its prompt only one time.
    func grantBoxTurnedOn() { notice.authorize() }

    private func agentTakeEnded(_ take: Int) {
        guard let ended = agentRecord.take, ended.take == take else { return }
        notice.remove(ended.noticeID)
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
