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
    /// One bounce of the Dock icon at the start of an agent take in the background (decision 0050).
    var inform: @MainActor () -> Void = { _ = NSApp.requestUserAttention(.informationalRequest) }
}

/// The agent of a request that ended with no answer. The banner shows until the next edit.
struct ConsentExpiredShown: Equatable {
    let agent: String?
    let revision: Int
}

/// One record request of an agent (decision 0048). The window resolves the tracks and the start
/// at the ask, so the take records what the sheet shows. It is `checking` while the app reads the
/// disk room (decision 0050), `waiting` while the sheet shows, and `starting` after Record.
/// `begin()` moves to `starting` and stops the end of the answer time in one step. `finish` gives
/// the reply once, stops the timer, and ends the activity token.
@MainActor @Observable
final class ConsentRequest {
    enum Phase { case checking, waiting, starting }

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
    /// The names of the request tracks with an app route (C9).
    let appTracks: [String]
    private(set) var phase = Phase.checking
    /// True when a press of Record counts (C8). The window sets it.
    var recordEnabled = false
    /// The time that the sheet window became key, or nil while it is not key.
    @ObservationIgnored var keySince: ContinuousClock.Instant?
    /// The wait that enables Record after the click delay.
    @ObservationIgnored var keyWait: Task<Void, Never>?
    /// The observers of the key state of the sheet window.
    @ObservationIgnored var keyObservers: [any NSObjectProtocol] = []
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
        appTracks = tracks.filter { if case .app = $0.route { true } else { false } }.map(\.name)
        activity = LatencyActivity(reason: Self.activityReason)
    }

    /// Waits for the one answer. The window calls it right after the ask, with no await between.
    func wait() async -> RecordAnswer { await withCheckedContinuation { reply = $0 } }

    /// The checks passed: the sheet shows.
    func ask() { phase = .waiting }

    func begin() {
        phase = .starting
        expiry?.cancel()
    }

    func finish(_ answer: RecordAnswer) {
        expiry?.cancel()
        keyWait?.cancel()
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
        keyObservers = []
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
        // A new connection of the bridge ends the grant (decision 0050): the old one is gone.
        if agentRecord.grant?.connection != connection { agentRecord.grant = nil }
        if let refusal = askRefusal(nil) { return refusal }
        guard case .open(let studio) = phase else { return .busy(.closing) }
        if agentRecord.tooMany(at: agentRecord.now()) { return .tooMany }
        let tracks: [Track]
        do throws(StudioError) { tracks = try consentTracks(request.armed, in: studio.session) } catch {
            return .refused(error)
        }
        let start = request.playhead ?? studio.playhead
        let consent = ConsentRequest(
            agent: agent, tracks: tracks, start: start, seconds: request.seconds,
            over: recordOverTracks(studio.session, request.armed, from: start), connection: connection)
        // The request holds the window busy for agents during the read of the disk room.
        self.consent = consent
        let left = await agentRecord.readRecordTime(studio, consent.tracks)
        if let refusal = askRefusal(consent) ?? (Task.isCancelled ? .ended : nil) {
            if self.consent === consent { endConsent(refusal) }
            return refusal
        }
        if let left, left < .seconds(consent.seconds) {
            let refusal = RecordAnswer.noRoom(minutes: Int(left / .seconds(60)))
            endConsent(refusal)
            return refusal
        }
        agentRecord.asks.append(agentRecord.now())
        if grantCovers(consent) { return await grantTake(consent) }
        consent.ask()
        consent.recordEnabled = agentRecord.clickDelay <= .zero
        if agentRecord.followsKey { observeKey(consent) }
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
        // A second guard of the click delay, after the disabled button (C8).
        guard canPressRecord(consent) else { return }
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
        if case .started(let take) = start { agentTakeStarted(consent, take: take, byGrant: false) }
        endConsent(answer(start, consent, grant: grant))
    }

    /// Always Ask Again: the next request of the agent shows the sheet (decision 0050).
    func alwaysAskAgain() { agentRecord.grant = nil }

    /// Close and Quit: a request that checks or waits ends as closed. A request that starts
    /// answers with its start. The window grant ends.
    func closeConsent() {
        agentRecord.grant = nil
        if let consent, consent.phase != .starting { endConsent(.closed) }
    }

    /// True while a request waits or starts: then Command-R is off. A request that the app checks
    /// does not hold it (decision 0050).
    var consentHoldsRecord: Bool { consent.map { $0.phase != .checking } ?? false }

    /// Command-R during the check of a request: the request ends, and the agent gets busy.
    func endCheckingConsent() {
        if consent?.phase == .checking { endConsent(.busy(.task)) }
    }

    /// The guards of 0048, before and after each await of `askRecord`. After an await, `request`
    /// is the request of the call: when the window does not have it any more (Command-R or a
    /// close ended it), the call is busy or closed.
    private func askRefusal(_ request: ConsentRequest?) -> RecordAnswer? {
        if let request {
            guard consent === request else {
                if case .open = phase { return .busy(.task) }
                return .closed
            }
        } else if consent != nil {
            return .busy(.asking)
        }
        guard case .open(let studio) = phase else { return .busy(.closing) }
        if window?.isMiniaturized == true { return .minimized }
        if showsDialog { return .busy(.dialog) }
        guard studio.isIdle, studio.pendingTake == nil, importJob == nil else { return .busy(.task) }
        return nil
    }

    /// True when a press of Record counts: the sheet window was key for the click delay with no
    /// break (C8).
    func canPressRecord(_ consent: ConsentRequest) -> Bool {
        let delay = agentRecord.clickDelay
        guard delay > .zero else { return true }
        guard let since = consent.keySince else { return false }
        return agentRecord.now() - since >= delay
    }

    /// Follows the key state of the sheet window. SwiftUI shows the sheet after `consent` is
    /// set, so the observers take each window and compare it with the sheet at the delivery.
    private func observeKey(_ consent: ConsentRequest) {
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        consent.keyObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self, weak consent] note in
                let object = (note.object as AnyObject?).map(ObjectIdentifier.init)
                let became = note.name == NSWindow.didBecomeKeyNotification
                MainActor.assumeIsolated {
                    guard let self, let consent, let object,
                        object == self.window?.attachedSheet.map(ObjectIdentifier.init)
                    else { return }
                    self.sheetKey(consent, became: became)
                }
            }
        }
    }

    /// The sheet shows: when it is key already, the key time starts now.
    func consentSheetShown() {
        guard agentRecord.followsKey, let consent, consent.keySince == nil, window?.attachedSheet?.isKeyWindow == true
        else { return }
        sheetKey(consent, became: true)
    }

    /// The sheet window became key or resigned: Record is disabled, and enabled again after the
    /// click delay of key time.
    func sheetKey(_ consent: ConsentRequest, became: Bool) {
        guard consent.phase == .waiting else { return }
        consent.keyWait?.cancel()
        consent.keySince = became ? agentRecord.now() : nil
        consent.recordEnabled = canPressRecord(consent)
        guard became, !consent.recordEnabled, let since = consent.keySince else { return }
        let (wait, end) = (agentRecord.delayWait, since + agentRecord.clickDelay)
        consent.keyWait = Task { [weak self, weak consent] in
            await wait(end)
            guard !Task.isCancelled, let self, let consent, consent.keySince == since else { return }
            consent.recordEnabled = canPressRecord(consent)
        }
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
        if case .started(let take) = start { agentTakeStarted(consent, take: take, byGrant: true) }
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
        logAgentEnd(consent, answer)
        consent.finish(answer)
    }
}
