import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Observation

/// What the shared record body of Command-R and the consent sheet gave (decision 0048).
enum RecordStart: Equatable {
    case started(take: Int)
    /// A guard refused the start on an open window, with this cause.
    case busy(AgentBusy)
    /// The window is not open, or it changed during the microphone prompt.
    case closed
    /// The check of the start was false: the routes of a grant take changed (decision 0050).
    case changed
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

    static let activityReason = "An agent asks the user to record."

    let agent: AgentName
    let tracks: [TrackID]
    let names: [String]
    let start: Frames
    let seconds: Double
    /// The names of the request tracks with a clip after the start (C15).
    let over: [String]
    /// The bridge connection of the call, or nil (decision 0050).
    let connection: AgentConnection?
    /// True when the sheet shows the grant checkbox (C1), and the state of that checkbox.
    let offersGrant: Bool
    var grantChecked = false
    private(set) var phase = Phase.waiting
    /// Keeps the timer of the answer time on time while App Nap could slow a hidden app. It lets
    /// the system sleep (probe P3).
    @ObservationIgnored private(set) var activity: LatencyActivity?
    @ObservationIgnored var expiry: Task<Void, Never>?
    @ObservationIgnored var attentionRequest: Int?
    @ObservationIgnored private var reply: CheckedContinuation<RecordAnswer, Never>?

    init(
        agent: AgentName, tracks: [Track], start: Frames, seconds: Double, over: [String],
        connection: AgentConnection? = nil
    ) {
        (self.agent, self.start, self.seconds, self.over) = (agent, start, seconds, over)
        (self.tracks, names) = (tracks.map(\.id), tracks.map(\.name))
        self.connection = connection
        offersGrant = ConsentGrant.offered(tracks: tracks, over: over, seconds: seconds, connection: connection)
        activity = LatencyActivity(reason: Self.activityReason)
    }

    /// Waits for the one answer. The window calls it right after the ask, with no await between.
    func wait() async -> RecordAnswer { await withCheckedContinuation { reply = $0 } }

    func begin() {
        phase = .starting
        expiry?.cancel()
    }

    func finish(_ answer: RecordAnswer) {
        expiry?.cancel()
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
    /// True while the window shows an alert, a step of Export, or a sheet: then the sheet of an
    /// agent record or export cannot show (decisions 0048 and 0049).
    var showsDialog: Bool { alert != nil || exportStep != nil || window?.attachedSheet != nil }

    /// An agent asks to record (decision 0048). A refusal answers at once; a request that the
    /// window grant covers starts with no sheet (decision 0050); else the sheet shows, and the
    /// answer comes after Record and the start, Don't Record, the end of the answer time, or a
    /// close. The window does not come to the front: in the background, the Dock asks for
    /// attention.
    func askRecord(_ request: RecordRequest, agent: AgentName, connection: AgentConnection? = nil) async
        -> RecordAnswer
    {
        // The agent stopped waiting before the main actor got the call: no sheet, no Dock bounce.
        if Task.isCancelled { return .ended }
        if consent != nil { return .busy(.asking) }
        guard case .open(let studio) = phase else { return .busy(.closing) }
        if window?.isMiniaturized == true { return .minimized }
        if showsDialog { return .busy(.dialog) }
        guard studio.isIdle, studio.pendingTake == nil, importJob == nil else { return .busy(.task) }
        let tracks: [Track]
        do throws(StudioError) { tracks = try consentTracks(request.armed, in: studio.session) } catch {
            return .refused(error)
        }
        let start = request.playhead ?? studio.playhead
        let consent = ConsentRequest(
            agent: agent, tracks: tracks, start: start, seconds: request.seconds,
            over: recordOverTracks(studio.session, request.armed, from: start), connection: connection)
        if grantCovers(consent) { return await grantTake(consent) }
        self.consent = consent
        consentExpired = nil
        if !attention.isActive() { consent.attentionRequest = attention.request() }
        let wait = consentWait
        consent.expiry = Task { [weak self, weak consent] in
            await wait(RecordRequest.answerLimit)
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
        let start = await startTake(armed: consent.tracks, playhead: consent.start, seconds: consent.seconds)
        var grant: GrantNote?
        if case .started = start, consent.grantChecked, let connection = consent.connection,
            let session = studio?.session
        {
            let routes = consent.tracks.compactMap { id in session.track(id)?.route.map { (id, $0) } }
            let given = ConsentGrant(
                connection: connection, routes: Dictionary(uniqueKeysWithValues: routes),
                end: agentRecord.now() + ConsentGrant.lifetime, wallEnd: .now + ConsentGrant.lifetime / .seconds(1))
            agentRecord.grant = given
            grant = GrantNote(end: given.wallEnd, secondsLeft: given.secondsLeft, noSheet: false)
        }
        endConsent(answer(start, consent, grant: grant))
    }

    /// Always Ask Again: the next request of the agent shows the sheet (decision 0050).
    func alwaysAskAgain() { agentRecord.grant = nil }

    /// Close and Quit: a waiting request ends as closed. A request that starts answers with its
    /// start. The window grant ends.
    func closeConsent() {
        agentRecord.grant = nil
        if consent?.phase == .waiting { endConsent(.closed) }
    }

    /// True when the window grant covers the request now (decision 0050).
    private func grantCovers(_ consent: ConsentRequest) -> Bool {
        guard let grant = agentRecord.grant, let session = studio?.session else { return false }
        return grant.covers(
            consent.tracks, seconds: consent.seconds, connection: consent.connection, in: session,
            over: recordOverTracks(session, consent.tracks, from: consent.start), now: agentRecord.now())
    }

    /// A grant take: no sheet and no answer time. The request holds the window busy for agents
    /// during the start, and the grant check runs again after the microphone prompt.
    private func grantTake(_ consent: ConsentRequest) async -> RecordAnswer {
        self.consent = consent
        consentExpired = nil
        consent.begin()
        let start = await startTake(armed: consent.tracks, playhead: consent.start, seconds: consent.seconds) {
            [weak self, weak consent] in
            guard let self, let consent else { return false }
            return grantCovers(consent)
        }
        var grant: GrantNote?
        if case .started = start, var given = agentRecord.grant {
            given.secondsLeft -= consent.seconds
            agentRecord.grant = given
            grant = GrantNote(end: given.wallEnd, secondsLeft: given.secondsLeft, noSheet: true)
        }
        let answer = answer(start, consent, grant: grant)
        if self.consent === consent { endConsent(answer) }
        return answer
    }

    private func answer(_ start: RecordStart, _ consent: ConsentRequest, grant: GrantNote?) -> RecordAnswer {
        switch start {
        case .started(let take): .started(take: take, tracks: consent.names, seconds: consent.seconds, grant: grant)
        case .busy(let busy): .busy(busy)
        case .closed: .closed
        case .changed: .grantChanged
        case .failed(let error): .refused(error)
        }
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
}
