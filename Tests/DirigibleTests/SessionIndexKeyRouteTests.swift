import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The keys of the session index list reach the lanes and the menu items, never the Silences list. The window and the
/// keys come from `SilencesInspectorTests`, whose list is the near input.
@Suite(.serialized) @MainActor struct SessionIndexKeyRouteTests {
    let base: SilencesInspectorTests

    init() throws { base = try SilencesInspectorTests() }

    @Test func returnAndDeleteInTheIndexLeaveTheSilences() async throws {
        defer { base.defaults.removePersistentDomain(forName: base.suite) }
        let (model, studio, window, silenceTable) = try await base.focusedList("index-keys")
        let app = base.app
        let actions = { base.rows(model).map(\.action) }

        // The near input: with the focus in the Silences table, Delete sets the selected row to Skip.
        model.selectSilences([0])
        app.timeline(.delete, event: key(.keyDown, "\u{7f}", code: 51, in: window), in: window)
        try #require(
            actions() == [.skip, .shorten], "Delete in the Silences list did not reach the rows: \(actions())")
        model.setSilenceAction(.shorten, rows: [0, 1])
        try #require(model.canApplySilences && !studio.canUndo, "the plan is ready to apply")

        model.toggleIndex()
        await until("the index table shows") { model.leadingPane.table != nil }
        let index = try #require(model.leadingPane.table)
        try #require(index !== silenceTable, "the index has its own table")
        try #require(window.makeFirstResponder(index), "the index takes the focus")

        app.timeline(.renameTrack, event: base.returnKey(in: window), in: window)
        #expect(!studio.canUndo && model.silences.note == nil, "Return in the index applied the plan")
        model.selectSilences([0])
        app.timeline(.delete, event: key(.keyDown, "\u{7f}", code: 51, in: window), in: window)
        #expect(actions() == [.shorten, .shorten], "Delete in the index set a silence to Skip: \(actions())")
        #expect(!studio.canUndo && model.canApplySilences, "the silence actions kept")
        await model.close()
    }
}
