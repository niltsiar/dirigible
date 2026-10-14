import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation
import Testing

@testable import DirigibleApp

/// The notification of an agent take (decision 0050, C14): one post in the background, its Stop
/// action, its removal at the take end, and the permission ask at the checkbox.
extension ConsentTests {
    /// The calls of the notification seam of a window.
    final class Notices {
        var asks = 0
        var posts: [(id: String, title: String, body: String, info: [String: String])] = []
        var removed: [String] = []
    }

    func watchNotices(_ model: SessionWindow, active: Bool) -> Notices {
        let notices = Notices()
        model.attention = ConsentAttention(isActive: { active }, request: { 0 }, cancel: { _ in })
        model.notice = AgentTakeNotice(
            authorize: { notices.asks += 1 }, post: { notices.posts.append(($0, $1, $2, $3)) },
            remove: { notices.removed.append($0) })
        return notices
    }

    /// In the background: one post with the take, the tracks, the quoted name, the package, and
    /// the take number. In front: no post (the control).
    @Test(arguments: [false, true]) func backgroundTakePostsOneNotice(active: Bool) async throws {
        let (model, studio) = try await window()
        let notices = watchNotices(model, active: active)
        _ = try await clickTake(model)
        #expect(studio.transport == .recording(take: 1))
        if active {
            #expect(notices.posts.isEmpty)
        } else {
            let take = try #require(model.agentRecord.take)
            let post = try #require(notices.posts.first)
            #expect(notices.posts.count == 1)
            #expect(post.id == take.noticeID && post.title == "consent")
            #expect(post.body == model.agentTakeText(take, now: take.since))
            #expect(post.info == [AgentTakeNotice.idKey: take.noticeID])
        }
        await model.stop()
        await model.close()
    }

    /// Stop of the notification ends that agent take, also after a move of the package, and the
    /// take end removes the notification.
    @Test func noticeStopEndsTheTake() async throws {
        let (model, studio) = try await window()
        let notices = watchNotices(model, active: false)
        _ = try await clickTake(model, seconds: 30)
        // The user info goes through the decode of the delegate, as from the notification center.
        let posted = try #require(notices.posts.first)
        app.rekey(model, to: folder.url.appending(path: "moved.dirigible"))
        let id = try #require(AgentTakeNotice.id(of: posted.info))
        await app.noticeStop(id)
        #expect(studio.transport != .recording(take: 1), "Stop of the notification stopped the take")
        await until("the take ends") { studio.transport == .idle && model.agentRecord.take == nil }
        #expect(notices.removed == [posted.id])
        await model.close()
    }

    /// An agent take that ended before its start event gets no notification, no badge, and no
    /// announcement (item 3 of code gate 2).
    @Test func takeEndBeforeTheStartEvent() async throws {
        let (model, studio) = try await window()
        let dock = watchDock(model)
        let notices = watchNotices(model, active: false)
        let host = try #require(studio.session.track("t1"))
        let consent = ConsentRequest(agent: agent, tracks: [host], start: 0, seconds: 1, over: [])
        #expect(studio.transport == .idle)
        model.agentTakeStarted(consent, take: 1)
        #expect(model.agentRecord.take == nil)
        #expect(dock.badges.allSatisfy { $0 == nil }, "\(dock.badges)")
        #expect(notices.posts.isEmpty && dock.announced.isEmpty)
        await model.close()
    }

    /// The Stop of the notification of agent take 1 does not stop take 2 of the person.
    @Test func oldStopKeepsAPersonTake() async throws {
        let (model, studio) = try await window()
        let notices = watchNotices(model, active: false)
        _ = try await clickTake(model)
        let first = try #require(notices.posts.first?.id)
        await model.stop()
        await until("the agent take ends") { studio.transport == .idle && model.agentRecord.take == nil }
        model.armed = ["t1"]
        await model.record()
        #expect(studio.transport == .recording(take: 2))

        await app.noticeStop(first)
        #expect(studio.transport == .recording(take: 2), "the take of the person goes on")
        await model.stop()
        await model.close()
    }

    /// A turn-on of the checkbox asks for the permission; a sheet with the box off does not.
    @Test(arguments: [false, true]) func checkboxAsksForThePermission(turnOn: Bool) async throws {
        let (model, _) = try await window()
        let notices = watchNotices(model, active: true)
        let answer = ask(model, seconds: 0.3, connection: Self.seven)
        let sheet = try await sheet(model)
        if turnOn { try #require(grantBox(in: sheet)).performClick(nil) }
        #expect(notices.asks == (turnOn ? 1 : 0))
        await model.answerConsent(record: false)
        #expect(await answer.value == .declined)
        await model.close()
    }
}
