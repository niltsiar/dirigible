import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Edit-commands criterion 13 on a real session window: the replaced Edit items send their
/// selector from the first responder of the key window (probes E2, E3, E6). The tests call the
/// item action with that window as the key window.
@Suite(.serialized) @MainActor struct EditRoutingTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// The field text changes; the session, the undo state, the Marks, and the package do not.
    /// Select All and Delete, not Copy: a copy: of the field editor writes the general pasteboard
    /// of the user. Select All gets its Command-A key-down, which the item does not forward.
    /// Controls: a send that starts at the window runs Select All and Delete on the session; a
    /// forward of Command-A selects no text.
    @Test func theEditItemsGoToAFocusedFieldAndLeaveTheSession() async throws {
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        let saves = SaveCounter(studio)
        let marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        model.timeline.marks = marks
        let editor = try await focusName(in: window)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let session = studio.session

        app.timeline(.selectAll, event: commandKey("a", code: 0, in: window), in: window)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 2))
        app.timeline(.delete, event: nil, in: window)

        #expect(editor.string == "")
        #expect(studio.session == session && !studio.canUndo)
        #expect(model.timeline.marks == marks && model.clipboard == nil)
        await studio.settle()
        #expect(saves.writes == 0)
        await model.close()
    }

    /// Control: a window with no cut:, copy:, paste:, or delete: leaves the session.
    @Test func theEditItemsRunTheTimelineWithTheLanesFocused() async throws {
        let (model, studio, window, view) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        #expect(window.makeFirstResponder(view.lanes))
        await studio.perform(.seek(.start))
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])

        app.timeline(.copy, event: nil, in: window)
        #expect(model.clipboard?.lanes.map(\.source) == ["t1"])
        app.timeline(.delete, event: nil, in: window)
        #expect(studio.session.track("t1")?.clips.first?.start == 48_000)
        app.timeline(.selectAll, event: nil, in: window)
        #expect(model.timeline.marks == Marks.all(in: studio.session))
        app.timeline(.cut, event: nil, in: window)
        #expect(studio.session.tracks.allSatisfy { $0.clips.isEmpty })
        #expect(model.clipboard?.lanes.map(\.source) == ["t1", "t2"])
        app.timeline(.paste, event: nil, in: window)
        #expect(studio.session.tracks.map { $0.clips.map(\.range) } == [[48_000..<2_880_000], [0..<2_880_000]])
        await model.close()
    }

    /// Each run function names its commands and ignores the others (code gate 1 item 5). Controls:
    /// a nested `default:` that runs Delete Marker, Cut or Delete, or Nudge Right for a command of
    /// another group changes the session.
    @Test func aRunFunctionIgnoresTheCommandsOfOtherGroups() async throws {
        let (model, studio, _, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        try studio.edit { s throws(SessionError) in
            try s.setMarker(Marker(id: "m1", name: "One", position: 48_000, kind: .marker))
        }
        model.timeline.marker = "m1"
        model.timeline.marks = Marks(inPoint: 0, outPoint: 2_880_000, tracks: ["t1"])
        let before = studio.session

        model.runMarker(.split, studio)
        model.runClipboard(.split, studio)
        model.runSplitOrNudge(.addMarker, studio)

        #expect(studio.session == before && model.alert == nil)
        #expect(model.timeline.marker == "m1" && model.clipboard == nil)
        await model.close()
    }
}
