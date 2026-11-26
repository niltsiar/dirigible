import AppKit
import DirigibleCore
import DirigibleMCP
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The window grant of an agent record request (decision 0050).
extension ConsentTests {
    static let seven = AgentConnection(serial: 7)

    /// The grant checkbox of the sheet, or nil.
    func grantBox(in sheet: NSWindow) -> GrantCheckbox? {
        func boxes(_ view: NSView) -> [GrantCheckbox] {
            (view as? GrantCheckbox).map { [$0] } ?? view.subviews.flatMap(boxes)
        }
        sheet.contentView?.layoutSubtreeIfNeeded()
        return sheet.contentView.map(boxes)?.first
    }

    /// `t2` "Guest" gets channel 2 of `duo` as a mono track, so a take can record both tracks.
    func routeGuest(_ studio: Studio) throws {
        try studio.edit(ripple: false) { s throws(SessionError) in
            try s.setLayout(.mono, route: .device(uid: "duo", channels: .mono(2)), track: "t2")
        }
    }

    /// A click take with the grant checkbox on, from connection 7; the take then stops.
    func giveGrant(_ model: SessionWindow, _ studio: Studio, _ armed: [TrackID] = ["t1"]) async throws {
        let answer = ask(model, armed, seconds: 0.3, connection: Self.seven)
        let sheet = try await sheet(model)
        try #require(grantBox(in: sheet)).performClick(nil)
        try click(record: true, in: sheet)
        guard case .started(_, _, _, _, let grant?) = await answer.value else {
            Issue.record("the click take with the box on gives no grant")
            return
        }
        #expect(!grant.noSheet && grant.secondsLeft == 7200)
        await model.stop()
        await until("the take ends") { studio.transport == .idle }
    }

    // MARK: C3

    /// C3: a later request of the same connection on the same track starts with no sheet, and
    /// its length comes off the length left.
    @Test func grantTakeStartsWithNoSheet() async throws {
        let (model, studio) = try await window()
        try await giveGrant(model, studio)

        let answer = await ask(model, seconds: 0.3, connection: Self.seven).value

        guard case .started(2, ["Host"], 0.3, nil, let grant?) = answer else {
            Issue.record("no grant take: \(answer)")
            return await model.close()
        }
        #expect(grant.noSheet && grant.secondsLeft == 7200 - 0.3)
        #expect(model.agentRecord.grant?.secondsLeft == 7200 - 0.3, "the length left")
        #expect(model.consent == nil && model.window?.attachedSheet == nil, "no sheet")
        #expect(studio.transport == .recording(take: 2))
        guard case .result(let text, false) = answer.reply(package: "p") else {
            Issue.record("an error")
            return
        }
        #expect(text.hasPrefix("Take 2 records on Host for 0.3 s with no sheet: a window grant of the user covers"))
        #expect(text.contains("with 119 min of takes left. A cancel of a call or a new agent session makes a new"))
        await model.stop()
        await model.close()
    }

    enum GrantCase: String, CaseIterable {
        case otherConnection, subset, superset, recordOver, otherDevice, otherChannels, appRoute, readded
        case tooLong, lengthLeft, expired, beforeEnd

        /// True when the grant still covers the request: the passing side of a threshold pair.
        var covers: Bool { [.lengthLeft, .beforeEnd].contains(self) }
    }

    /// C3 negative control: each change shows the sheet; the passing value of each threshold
    /// starts with no sheet.
    @Test(arguments: GrantCase.allCases) func grantDoesNotCover(_ change: GrantCase) async throws {
        let (model, studio) = try await window()
        try routeGuest(studio)
        var now = ContinuousClock.now
        model.agentRecord.now = { now }
        try await giveGrant(model, studio, change == .subset ? ["t1", "t2"] : ["t1"])
        var (armed, seconds, connection) = ([TrackID("t1")], 0.3, Self.seven)
        func route(_ route: Route, _ layout: ChannelLayout = .mono) throws {
            try studio.edit(ripple: false) { s throws(SessionError) in
                try s.setLayout(layout, route: route, track: "t1")
            }
        }
        switch change {
        case .otherConnection: connection = AgentConnection(serial: 8)
        case .subset: break
        case .superset: armed = ["t1", "t2"]
        case .recordOver:
            try studio.edit(ripple: false) { s throws(SessionError) in
                try s.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 48_000))
                try s.place(Clip(id: "c", file: "f", start: 1000, offset: 0, length: 1000), on: "t1")
            }
        case .otherDevice: try route(.device(uid: "other", channels: .mono(1)))
        case .otherChannels: try route(.device(uid: "duo", channels: .mono(2)))
        case .appRoute: try route(.app(bundleID: "us.zoom.xos"), .stereo)
        case .readded:
            try studio.edit(ripple: false) { s throws(SessionError) in
                try s.removeTrack("t1")
                try s.addTrack("t1", name: "Host", layout: .mono)
                try s.setRoute(.device(uid: "other", channels: .mono(1)), track: "t1")
            }
        case .tooLong, .lengthLeft:
            model.agentRecord.grant?.secondsLeft = 10
            seconds = change == .tooLong ? 11 : 10
        case .expired: now += .seconds(3601)
        case .beforeEnd: now += .seconds(3599)
        }

        let answer = ask(model, armed, seconds: seconds, connection: connection)

        if change.covers {
            let value = await answer.value
            #expect(isGrantTake(value), "\(change): \(value)")
            await model.stop()
        } else {
            _ = try await sheet(model)
            await model.answerConsent(record: false)
            #expect(await answer.value == .declined, "\(change)")
        }
        await model.close()
    }

    func isGrantTake(_ answer: RecordAnswer) -> Bool {
        if case .started(_, _, _, _, let grant?) = answer { return grant.noSheet }
        return false
    }

    /// C3: a route change of a grant track during the microphone prompt starts no take.
    @Test func routeChangeDuringThePrompt() async throws {
        let (model, studio) = try await window()
        try await giveGrant(model, studio)
        let prompt = holdPrompt(model, studio)
        let answer = ask(model, seconds: 0.3, connection: Self.seven)
        await until("the prompt waits") { prompt.asked() }
        #expect(model.window?.attachedSheet == nil, "a grant take shows no sheet")
        try studio.edit(ripple: false) { s throws(SessionError) in
            try s.setRoute(.device(uid: "duo", channels: .mono(2)), track: "t1")
        }

        prompt.give()

        let value = await answer.value
        #expect(value == .grantChanged, "\(value)")
        #expect(studio.transport == .idle && model.consent == nil)
        guard case .result(let text, true) = value.reply(package: "p") else {
            Issue.record("not an error")
            return
        }
        #expect(text == "A track route changed during the start. Ask again: the sheet shows.")
        await model.close()
    }

    /// Item 2 of code gate 1: a grant never holds an app route.
    @Test func noGrantOfAnAppRoute() {
        let (end, connection) = (ContinuousClock.now, Self.seven)
        let device = Route.device(uid: "duo", channels: .mono(1))
        #expect(ConsentGrant(connection: connection, routes: ["t1": device], end: end, wallEnd: .now) != nil)
        let app = Route.app(bundleID: "us.zoom.xos")
        #expect(
            ConsentGrant(connection: connection, routes: ["t1": device, "t2": app], end: end, wallEnd: .now) == nil)
    }

    /// Item 2 of code gate 1: a route change between the click and the start, to an app or to
    /// another channel, starts no take and stores no grant. The sheet showed the old routes.
    @Test(arguments: [true, false]) func routeChangeAfterTheClick(app: Bool) async throws {
        let (model, studio) = try await window()
        let prompt = holdPrompt(model, studio)
        let answer = ask(model, seconds: 0.3, connection: Self.seven)
        let sheet = try await sheet(model)
        try #require(grantBox(in: sheet)).performClick(nil)
        try click(record: true, in: sheet)
        await until("the prompt waits") { prompt.asked() }
        try studio.edit(ripple: false) { s throws(SessionError) in
            if app {
                try s.setLayout(.stereo, route: .app(bundleID: "us.zoom.xos"), track: "t1")
            } else {
                try s.setRoute(.device(uid: "duo", channels: .mono(2)), track: "t1")
            }
        }

        prompt.give()

        let value = await answer.value
        #expect(value == .grantChanged, "\(value)")
        #expect(model.agentRecord.grant == nil && studio.transport == .idle)
        await model.close()
    }

    // MARK: C1, C2, C21

    enum OfferCase: String, CaseIterable { case microphones, tooLong, appTrack, recordOver, noConnection }

    /// C1: the checkbox and its help line show only when the request can get a grant. C21: the
    /// help line names the reconnect in both languages.
    @Test(arguments: OfferCase.allCases) func checkboxOnlyWhenEligible(_ offer: OfferCase) async throws {
        let (model, studio) = try await window()
        var (seconds, connection): (Double, AgentConnection?) = (7200, Self.seven)
        switch offer {
        case .microphones: break
        case .tooLong: seconds = 7200.5
        case .appTrack:
            try studio.edit(ripple: false) { s throws(SessionError) in
                try s.setLayout(.stereo, route: .app(bundleID: "us.zoom.xos"), track: "t1")
            }
        case .recordOver:
            try studio.edit(ripple: false) { s throws(SessionError) in
                try s.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 48_000))
                try s.place(Clip(id: "c", file: "f", start: 1000, offset: 0, length: 1000), on: "t1")
            }
        case .noConnection: connection = nil
        }
        let answer = ask(model, seconds: seconds, connection: connection)
        let sheet = try await sheet(model)
        if offer == .microphones {
            let box = try #require(grantBox(in: sheet))
            #expect(box.title == L10n.consentGrant.text && box.state == .off, "off at each new sheet")
            // The help line shows with the box; the tree of the SwiftUI host is empty in a test
            // process, so the on-screen check of S1 reads it.
            #expect(model.consent?.offersGrant == true)
        } else {
            #expect(grantBox(in: sheet) == nil, "\(offer): no checkbox")
            #expect(model.consent?.offersGrant == false, "\(offer): no help line")
        }
        await model.answerConsent(record: false)
        #expect(await answer.value == .declined)
        await model.close()
    }

    /// The help line gets its hours from the constants of 0050, in each language (item 5 of
    /// code gate 2).
    @Test func grantHelpFromTheConstants() throws {
        for (language, expected) in [
            (
                "en",
                "Ends when this window closes or 1 hour after your click. It also ends after 2 hours of later takes."
            ),
            (
                "es",
                "Termina al cerrar esta ventana o 1 hora después de tu clic. "
                    + "También termina después de 2 horas de tomas posteriores."
            ),
        ] {
            let template = try #require(try stringsTable(language)[L10n.consentGrantHelp.rawValue])
            let words = template.replacing("%1$@", with: "").replacing("%2$@", with: "")
            let digits = words.filter(\.isNumber)
            #expect(digits.isEmpty, "no hours in the text: \(template)")
            let locale = Locale(identifier: language)
            let text = String(
                format: template, grantHours(RecordRequest.grantLifetime, locale),
                grantHours(.seconds(RecordRequest.grantTakeSeconds), locale))
            #expect(text == expected)
        }
    }

    /// C2: Record with the box on stores the connection and the route of each track; with the box
    /// off, or with a start error, no grant.
    @Test(arguments: ["on", "off", "error"]) func grantOnlyWithTheBox(_ state: String) async throws {
        let (model, studio) = try await window()
        if state == "error" { studio.environment.microphoneAccess = { .denied } }
        let answer = ask(model, seconds: 0.3, connection: Self.seven)
        let sheet = try await sheet(model)
        if state != "off" { try #require(grantBox(in: sheet)).performClick(nil) }
        try click(record: true, in: sheet)
        _ = await answer.value
        let grant = model.agentRecord.grant
        if state == "on" {
            #expect(grant?.connection == Self.seven)
            #expect(grant?.routes.mapValues(\.route) == ["t1": .device(uid: "duo", channels: .mono(1))])
            #expect(grant?.secondsLeft == 7200, "the click take uses no grant length")
            await model.stop()
        } else {
            #expect(grant == nil, "\(state): no grant")
            model.alert = nil
        }
        await model.close()
    }

    // MARK: C4, C5, C6

    /// C4: Always Ask Again ends the grant: the next request shows the sheet.
    @Test func alwaysAskAgainEndsTheGrant() async throws {
        let (model, studio) = try await window()
        try await giveGrant(model, studio)
        model.alwaysAskAgain()
        let answer = ask(model, seconds: 0.3, connection: Self.seven)
        _ = try await sheet(model)
        await model.answerConsent(record: false)
        #expect(await answer.value == .declined)
        await model.close()
    }

    /// C4: a request on a new connection ends the grant, so the take row loses Always Ask Again and
    /// the old connection gets the sheet again.
    @Test func newConnectionEndsTheGrant() async throws {
        let (model, studio) = try await window()
        try await giveGrant(model, studio)
        let other = ask(model, seconds: 0.3, connection: AgentConnection(serial: 8))
        _ = try await sheet(model)
        #expect(model.agentRecord.grant == nil, "a new connection ends the grant")
        await model.answerConsent(record: false)
        #expect(await other.value == .declined)
        await until("the sheet goes") { model.window?.attachedSheet == nil }
        let again = ask(model, seconds: 0.3, connection: Self.seven)
        _ = try await sheet(model)
        await model.answerConsent(record: false)
        #expect(await again.value == .declined)
        await model.close()
    }

    /// C4: a new window on the same package shows the sheet for the same connection.
    @Test func closeEndsTheGrant() async throws {
        // The block drops the first studio, so its package lock goes before the next open.
        let url: URL
        do {
            let (model, studio) = try await window()
            try await giveGrant(model, studio)
            #expect(model.agentRecord.grant != nil)
            url = model.url
            await model.close()
        }
        let again = await app.open(url)
        let reopened = try #require(await again.opened() ? again.studio : nil)
        reopened.environment = hal.environment
        again.attention = ConsentAttention(isActive: { true }, request: { 0 }, cancel: { _ in })
        let answer = ask(again, seconds: 0.3, connection: Self.seven)
        _ = try await sheet(again)
        await again.answerConsent(record: false)
        #expect(await answer.value == .declined)
        await again.close()
    }

    /// C5: a covered request keeps the refusals of 0048, C10, and C11: a take that runs, a
    /// minimized window, no disk room, and the rate limit.
    @Test func grantKeepsTheRefusals() async throws {
        let (model, studio) = try await window()
        try await giveGrant(model, studio)
        studio.transport = .leveling
        #expect(await ask(model, seconds: 0.3, connection: Self.seven).value == .busy(.task))
        studio.transport = .idle
        model.window?.miniaturize(nil)
        await until("the window is minimized") { model.window?.isMiniaturized == true }
        #expect(await ask(model, seconds: 0.3, connection: Self.seven).value == .minimized)
        model.window?.deminiaturize(nil)
        await until("the window shows") { model.window?.isMiniaturized == false }
        let free = diskMargin + Int64(0.2 * 48_000 * 7)
        studio.environment.freeBytes = { _ in free }
        #expect(await ask(model, seconds: 0.3, connection: Self.seven).value == .noRoom(minutes: 0))
        studio.environment.freeBytes = { _ in .max / 2 }
        model.agentRecord.asks = Array(repeating: model.agentRecord.now(), count: 3)
        #expect(await ask(model, seconds: 0.3, connection: Self.seven).value == .tooMany)
        #expect(model.agentRecord.grant?.secondsLeft == 7200, "a refusal uses no length")
        await model.close()
    }

    /// C6: the checkbox refuses the key focus, so Space cannot change it.
    @Test func spaceDoesNotCheckTheGrant() async throws {
        let (model, _) = try await window()
        let answer = ask(model, connection: Self.seven)
        let sheet = try await sheet(model)
        let box = try #require(grantBox(in: sheet))
        #expect(!box.acceptsFirstResponder && !box.canBecomeKeyView, "the box refuses the key focus")

        sheet.makeFirstResponder(box)
        press(" ", code: 49, in: sheet)

        #expect(box.state == .off && model.consent?.grantChecked == false, "Space does not check it")
        box.performClick(nil)
        #expect(box.state == .on && model.consent?.grantChecked == true, "a click checks it")
        press("\u{1b}", code: 53, in: sheet)
        #expect(await answer.value == .declined)
        await model.close()
    }
}
