import DirigibleAudio
import DirigibleCore

/// Runs a transport tool on the studio of an open window (run agent-transport). Play and locate
/// refuse in a busy window; stop acts in each window state. The reply text comes from the
/// returned outcome only, with no read of the studio after the await.
@MainActor
func liveTransport(_ work: TransportWork, _ call: AgentCall, target: AgentTarget) async -> AgentReply {
    let studio = target.studio
    do throws(StudioError) {
        switch work {
        case .stop:
            return try await studio.stopPlayback().reply
        case .play(let from, let to):
            if let busy = target.busy ?? target.sheetCause() { return busyReply(busy, call) }
            return try await studio.play(from: from, to: to).reply
        case .locate(let frame):
            if let busy = target.busy ?? target.sheetCause() { return busyReply(busy, call) }
            return try await studio.locate(frame).reply
        }
    } catch .busy {
        // `stopPlayback()` throws `.busy` only for a take; play and locate throw it for a task.
        guard case .stop = work else { return busyReply(.task, call) }
        return .result(text: transportStopTakeMessage(call.path), isError: true)
    } catch {
        return .result(text: error.message(package: call.path), isError: true)
    }
}

private func busyReply(_ busy: AgentBusy, _ call: AgentCall) -> AgentReply {
    .result(text: busy.message(package: call.path), isError: true)
}
