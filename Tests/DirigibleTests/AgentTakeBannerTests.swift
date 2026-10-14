import AppKit
import DirigibleCore
import DirigibleMCP
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The notice of an agent take (decision 0050, C12 and C13): the take row, the announcement, the
/// Dock bounce, and the Dock badge.
extension ConsentTests {
    /// The counts of the Dock seams of `model` and of the app.
    final class Dock {
        var bounces = 0
        var badges: [String?] = []
        var announced: [(String, NSAccessibilityPriorityLevel)] = []
    }

    func watchDock(_ model: SessionWindow, active: Bool = true) -> Dock {
        let dock = Dock()
        model.attention = ConsentAttention(
            isActive: { active }, request: { 0 }, cancel: { _ in }, inform: { dock.bounces += 1 })
        app.dockBadge = { dock.badges.append($0) }
        model.chrome?.announce = { dock.announced.append(($0, $1)) }
        return dock
    }

    /// A click take of `seconds` from connection 7, with the grant box on when `grant`.
    func clickTake(_ model: SessionWindow, seconds: Double = 5, grant: Bool = false) async throws -> RecordAnswer {
        let answer = ask(model, seconds: seconds, connection: Self.seven)
        let sheet = try await sheet(model)
        if grant { try #require(grantBox(in: sheet)).performClick(nil) }
        try click(record: true, in: sheet)
        return await answer.value
    }

    // MARK: C12

    @Test(arguments: [false, true]) func agentTakeShowsTheRow(grant: Bool) async throws {
        let (model, studio) = try await window()
        _ = try await clickTake(model, grant: grant)
        let take = try #require(model.agentRecord.take)
        #expect(take.take == 1 && take.tracks == ["Host"] && take.agent == "Claude Code" && !take.byGrant)
        let row = model.agentTakeText(take, now: take.since + .seconds(1))
        #expect(row == L10n.takeAgent.format(1, "Host", "Claude Code", "0:04"), "\(row)")
        // The row shows Stop, and Always Ask Again while a grant lives. The tree of the SwiftUI
        // host is empty in a test process, so the on-screen check of S3 reads the buttons.
        #expect((model.agentRecord.grant != nil) == grant)
        #expect(studio.transport == .recording(take: 1))
        await model.stop()
        await until("the agent take ends") { model.agentRecord.take == nil }
        await model.close()
        let english = try stringsTable("en")
        #expect(
            english[L10n.takeAgent.rawValue] == "Take %1$lld records %2$@ for an AI agent (it says: “%3$@”) · %4$@ left"
        )
    }

    /// The control: a take of the person shows the row of today, with no agent text.
    @Test func personTakeShowsNoAgentRow() async throws {
        let (model, studio) = try await window()
        model.armed = ["t1"]
        await model.record()
        #expect(studio.transport == .recording(take: 1))
        #expect(model.agentRecord.take == nil, "no agent row")
        await model.stop()
        await model.close()
    }

    /// Stop of the row ends the take; Always Ask Again ends the grant (C4).
    @Test func stopEndsTheTake() async throws {
        let (model, studio) = try await window()
        _ = try await clickTake(model, grant: true)
        #expect(model.agentRecord.grant != nil)

        model.alwaysAskAgain()
        #expect(model.agentRecord.grant == nil, "Always Ask Again ends the grant")
        await model.stop()

        await until("the take ends") { studio.transport == .idle }
        #expect(studio.lastTake?.take == 1 && model.agentRecord.take == nil)
        await model.close()
    }

    /// The row does not take the key focus.
    @Test func bannerKeepsTheFocus() async throws {
        let (model, _) = try await window()
        let window = try #require(model.window)
        let before = window.firstResponder
        _ = try await clickTake(model)
        // A layout and a display pass draw the row now.
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(model.agentRecord.take != nil)
        #expect(window.firstResponder === before, "\(String(describing: window.firstResponder))")
        await model.stop()
        await model.close()
    }

    // MARK: C13

    /// One bounce in the background, none in front, none for a take of the person; the badge
    /// shows while the agent take records; one high announcement.
    @Test(arguments: ["front", "background", "person"]) func dockBadgeAndOneBounce(_ state: String) async throws {
        let (model, studio) = try await window()
        let dock = watchDock(model, active: state != "background")
        if state == "person" {
            model.armed = ["t1"]
            await model.record()
        } else {
            _ = try await clickTake(model)
        }
        #expect(studio.transport == .recording(take: 1))
        #expect(dock.bounces == (state == "background" ? 1 : 0), "\(state)")
        #expect(dock.badges == (state == "person" ? [] : [L10n.dockBadgeRecording.text]), "\(dock.badges)")
        #expect(dock.announced.filter { $0.1 == .high }.count == (state == "person" ? 0 : 1))
        await model.stop()
        await until("the badge goes") { state == "person" || dock.badges.last == .some(nil) }
        await model.close()
    }

    /// Two windows with agent takes: one ends, the badge stays; both end, it goes.
    @Test func badgeOfTwoWindows() async throws {
        let (one, first) = try await window("one")
        let (two, second) = try await window("two")
        let dock = watchDock(one)
        two.attention = one.attention
        _ = try await clickTake(one)
        _ = try await clickTake(two)
        #expect(app.windows.values.filter { $0.agentRecord.take != nil }.count == 2)

        await one.stop()
        await until("one take ends") { first.transport == .idle && one.agentRecord.take == nil }
        #expect(dock.badges.last == L10n.dockBadgeRecording.text, "the badge stays: \(dock.badges)")
        await two.stop()
        await until("both end") { second.transport == .idle && two.agentRecord.take == nil }
        #expect(dock.badges.last == .some(nil), "the badge goes: \(dock.badges)")
        await one.close()
        await two.close()
    }
}
