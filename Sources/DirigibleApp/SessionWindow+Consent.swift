import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Observation

/// What the shared record body of Command-R and the consent sheet gave (decision 0048).
enum RecordStart: Equatable {
    case started(take: Int)
    /// A guard refused the start, or the window changed during the microphone prompt.
    case notStarted
    case failed(StudioError)
}

/// The Dock attention of a record request (decision 0048). Tests give their own.
struct ConsentAttention {
    var isActive: @MainActor () -> Bool = { NSApp.isActive }
    var request: @MainActor () -> Int = { NSApp.requestUserAttention(.criticalRequest) }
    var cancel: @MainActor (Int) -> Void = { NSApp.cancelUserAttentionRequest($0) }
}

/// The agent of a request that ended with no answer. The banner shows until the next edit.
struct ConsentExpiredShown: Equatable {
    let agent: String?
    let revision: Int
}

/// One record request of an agent (decision 0048). The window resolves the tracks and the start
/// at the ask, so the take records what the sheet shows. `begin()` moves to `starting` and stops
/// the end of the answer time in one step. `finish` gives the reply once, stops the timer, and
/// ends the activity token.
@MainActor @Observable
final class ConsentRequest {
    enum Phase { case waiting, starting }

    let agent: AgentName
    let tracks: [TrackID]
    let names: [String]
    let start: Frames
    let seconds: Double
    /// The names of the request tracks with a clip after the start (C15).
    let over: [String]
    private(set) var phase = Phase.waiting
    /// Keeps the timer of the answer time on time while App Nap could slow a hidden app.
    @ObservationIgnored private(set) var activity: NSObjectProtocol?
    @ObservationIgnored var expiry: Task<Void, Never>?
    @ObservationIgnored var attentionRequest: Int?
    @ObservationIgnored private var reply: CheckedContinuation<RecordAnswer, Never>?

    init(agent: AgentName, tracks: [Track], start: Frames, seconds: Double, over: [String]) {
        (self.agent, self.start, self.seconds, self.over) = (agent, start, seconds, over)
        (self.tracks, names) = (tracks.map(\.id), tracks.map(\.name))
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated, reason: "An agent asks the user to record.")
    }

    /// Waits for the one answer. The window calls it right after the ask, with no await between.
    func wait() async -> RecordAnswer { await withCheckedContinuation { reply = $0 } }

    func begin() {
        phase = .starting
        expiry?.cancel()
    }

    func finish(_ answer: RecordAnswer) {
        expiry?.cancel()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        reply?.resume(returning: answer)
        reply = nil
    }
}

/// The tracks of a request, checked as the take start checks them: each one exists, has a
/// route, and is named once.
func consentTracks(_ ids: [TrackID], in session: Session) throws(StudioError) -> [Track] {
    var tracks: [Track] = []
    for id in ids {
        guard let track = session.track(id) else { throw .session(.unknownTrack(id)) }
        guard track.route != nil else { throw .noRoute(id) }
        guard !tracks.contains(where: { $0.id == id }) else { throw .channelInUse(id, id) }
        tracks.append(track)
    }
    return tracks
}

/// The names of `tracks` with a clip that ends after `start`, on the whole timeline: a take
/// from `start` records over them.
func recordOverTracks(_ session: Session, _ tracks: [TrackID], from start: Frames) -> [String] {
    tracks.compactMap { session.track($0) }.filter { $0.clips.contains { $0.end > start } }.map(\.name)
}

extension SessionWindow {
    /// An agent asks to record (decision 0048). A refusal answers at once; else the sheet shows,
    /// and the answer comes after Record and the start, Don't Record, the end of the answer time,
    /// or a close. The window does not come to the front: in the background, the Dock asks for
    /// attention.
    func askRecord(_ request: RecordRequest, agent: AgentName) async -> RecordAnswer {
        if consent != nil { return .waits }
        guard case .open(let studio) = phase else { return .busy(.closing) }
        if window?.isMiniaturized == true { return .minimized }
        if alert != nil || exportStep != nil || window?.attachedSheet != nil { return .busy(.dialog) }
        guard studio.isIdle, studio.pendingTake == nil, importJob == nil else { return .busy(.task) }
        let tracks: [Track]
        do throws(StudioError) { tracks = try consentTracks(request.armed, in: studio.session) } catch {
            return .refused(error)
        }
        let start = request.playhead ?? studio.playhead
        let consent = ConsentRequest(
            agent: agent, tracks: tracks, start: start, seconds: request.seconds,
            over: recordOverTracks(studio.session, request.armed, from: start))
        self.consent = consent
        consentExpired = nil
        if !attention.isActive() { consent.attentionRequest = attention.request() }
        let lifetime = consentLifetime
        consent.expiry = Task { [weak self, weak consent] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, let self, let consent else { return }
            end(consent, .noAnswer)
        }
        // The agent stops waiting when its bridge closes or the server stops (decision 0048).
        return await withTaskCancellationHandler {
            await consent.wait()
        } onCancel: {
            Task { @MainActor [weak self, weak consent] in
                guard let self, let consent else { return }
                end(consent, .ended)
            }
        }
    }

    /// Record and Don't Record of the sheet. Each acts only while the request waits.
    func answerConsent(record: Bool) async {
        guard let consent, consent.phase == .waiting else { return }
        guard record else { return endConsent(.declined) }
        consent.begin()
        switch await startTake(armed: consent.tracks, playhead: consent.start) {
        case .started(let take):
            endConsent(.started(take: take, tracks: consent.names, seconds: consent.seconds))
            stopTake(take, after: consent.seconds)
        case .notStarted: endConsent(.closed)
        case .failed(let error): endConsent(.refused(error))
        }
    }

    /// Close and Quit: a waiting request ends as closed. A request that starts answers with its
    /// start.
    func closeConsent() {
        if consent?.phase == .waiting { endConsent(.closed) }
    }

    /// Ends a waiting request with no answer of the user, and shows the info banner.
    private func end(_ request: ConsentRequest, _ answer: RecordAnswer) {
        guard consent === request, request.phase == .waiting else { return }
        consentExpired = ConsentExpiredShown(agent: request.agent.name, revision: studio?.sessionRevision ?? 0)
        endConsent(answer)
    }

    private func endConsent(_ answer: RecordAnswer) {
        guard let consent else { return }
        self.consent = nil
        if let id = consent.attentionRequest { attention.cancel(id) }
        consent.finish(answer)
    }

    /// Stops `take` after `seconds`, unless it ended first.
    private func stopTake(_ take: Int, after seconds: Double) {
        agentStop?.cancel()
        agentStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, studio?.transport == .recording(take: take) else { return }
            await stop()
        }
    }
}
