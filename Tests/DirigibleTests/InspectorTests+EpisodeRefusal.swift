import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The end rule of a refused episode draft (code gate 2 of the episode run), as an AppKit
/// formatter: the draft holds the focus until the user corrects it or presses Esc.
extension InspectorTests {
    /// Opens the Episode pane and refuses "0" in Number: one beep.
    func refusedNumber() async throws -> (SessionWindow, Studio, NSWindow, () -> Int) {
        let (model, studio, window, _) = try await open(try await package())
        var beeps = 0
        model.beep = { beeps += 1 }
        model.showEpisodeInfo()
        _ = try await episodeFields(window)
        model.typeEpisode("0", in: .number)
        model.commitEpisode()
        #expect(beeps == 1 && model.episodeDraft?.refused == true)
        return (model, studio, window, { beeps })
    }

    /// Item 1: a later commit of a refused draft beeps no more and keeps the draft.
    @Test func aRefusedDraftBeepsOnce() async throws {
        let (model, _, _, beeps) = try await refusedNumber()
        model.typeEpisode("0", in: .number)
        #expect(model.episodeDraft?.refused == true, "a field that gets the focus sends its text again")
        model.commitEpisode()
        model.commitDrafts()
        model.run(TimelineCommand.zoomIn)
        #expect(beeps() == 1, "beeps: \(beeps())")
        #expect(model.episodeDraft == EpisodeDraft(field: .number, shown: "", text: "0", refused: true))
        model.episodeDraft = nil
        await model.close()
    }

    /// Item 2: a key in another field keeps the refused draft, beeps, and gives the focus back.
    @Test func aKeyInAnotherFieldKeepsTheRefusedDraft() async throws {
        let (model, studio, _, beeps) = try await refusedNumber()
        model.typeEpisode("T", in: .title)
        #expect(model.episodeDraft?.field == .number && model.episodeDraft?.refused == true)
        #expect(beeps() == 2 && studio.session.episode.title == nil, "beeps: \(beeps())")
        await until(limit: .seconds(10), "the focus goes back to Number") { model.episodeFocus == .number }
        model.episodeDraft = nil
        await model.close()
    }

    /// Item 3 and item 5: the Clip tab and Hide Inspector keep the Episode pane shown.
    @Test func aRefusedDraftKeepsTheEpisodePaneShown() async throws {
        let (model, _, _, beeps) = try await refusedNumber()
        model.selectInspectorTab(.clip)
        model.run(TimelineCommand.zoomIn)
        #expect(model.inspectorTab == .episode && beeps() == 2, "beeps: \(beeps())")
        #expect(model.heldTabChanges == 1, "the picker is made again, so it shows Episode")
        model.toggleInspector()
        #expect(model.showsInspector && model.inspectorTab == .episode && beeps() == 3, "beeps: \(beeps())")
        model.episodeDraft = nil
        model.selectInspectorTab(.clip)
        #expect(model.inspectorTab == .clip, "after Esc the tab changes")
        await model.close()
    }

    /// Item 3: a new refusal at the tab change beeps once.
    @Test func aRefusalAtTheTabChangeBeepsOnce() async throws {
        let (model, _, window, _) = try await open(try await package())
        var beeps = 0
        model.beep = { beeps += 1 }
        model.showEpisodeInfo()
        _ = try await episodeFields(window)
        model.typeEpisode("0", in: .number)
        model.selectInspectorTab(.clip)
        model.run(TimelineCommand.zoomIn)
        #expect(model.inspectorTab == .episode && beeps == 1, "beeps: \(beeps)")
        model.episodeDraft = nil
        await model.close()
    }

    /// Item 4: Close and Quit stop on a refused draft, with the pane and the rule shown.
    @Test func closeAndQuitStopOnARefusedDraft() async throws {
        let (model, _, _, _) = try await refusedNumber()
        await model.close()
        #expect(model.studio != nil, "the window stays open")
        #expect(app.applicationShouldTerminate(NSApp) == .terminateCancel && !app.terminating)
        #expect(model.showsInspector && model.inspectorTab == .episode && model.episodeDraft?.refused == true)
        model.episodeDraft = nil
        await model.close()
        #expect(model.studio == nil, "after Esc the window closes")
    }

    /// Item 7: after an undo or an MCP edit, a draft that is not refused gives way to the new
    /// stored value, so a later commit does not undo the change.
    @Test func aStaleDraftGivesWayToTheStoredValue() async throws {
        let (model, studio, window, _) = try await open(try await package())
        model.showEpisodeInfo()
        _ = try await episodeFields(window)
        model.typeEpisode("A", in: .title)
        model.commitEpisode()
        model.typeEpisode("AB", in: .title)
        model.undo()
        #expect(studio.session.episode.title == nil, "the undo removed A")
        model.typeEpisode("ABC", in: .title)
        #expect(model.episodeDraft == EpisodeDraft(field: .title, shown: "", text: "ABC"), "a new draft")
        model.episodeDraft = EpisodeDraft(field: .title, shown: "A", text: "AB")
        model.commitEpisode()
        #expect(studio.session.episode.title == nil && model.episodeDraft == nil, "the stale draft went")
        await model.close()
    }

    /// Fix check: a focus move from the lanes into another field holds at once.
    @Test func aFocusMoveFromTheLanesHolds() async throws {
        let (model, _, window, beeps) = try await refusedNumber()
        model.focusLanes()
        await until("the lanes have the focus") { model.episodeFocus == nil }
        let title = try await episodeFields(window)[0]
        #expect(window.makeFirstResponder(title))
        await until(limit: .seconds(10), "the move into Title holds") { beeps() == 2 }
        // A window of a parallel suite can take the key focus, as in `waitForTitleFocus`.
        await until(limit: .seconds(10), "the focus goes back to Number") {
            model.episodeFocus == .number || !window.isKeyWindow
        }
        #expect(beeps() == 2 && model.episodeDraft?.refused == true, "beeps: \(beeps())")
        model.episodeDraft = nil
        await model.close()
    }

    /// Opens a window whose track records from `duo`, refuses "0" in Number, and starts a take:
    /// the take disables the pane.
    func refusedNumberInATake(_ hal: CountingHAL) async throws -> (SessionWindow, Studio) {
        let (model, studio, window, _) = try await open(try await package(device: "duo"))
        studio.environment = hal.environment
        model.showEpisodeInfo()
        _ = try await episodeFields(window)
        model.typeEpisode("0", in: .number)
        model.commitEpisode()
        await model.record()
        #expect(studio.transport == .recording(take: 1) && !model.canEdit)
        return (model, studio)
    }

    /// Fix check: Stop and Close during a take closes the window; the refused draft goes.
    @Test func closeDuringATakeDropsTheRefusedDraft() async throws {
        let hal = CountingHAL()
        let (model, studio) = try await refusedNumberInATake(hal)
        await model.close()
        #expect(model.studio == nil && studio.transport == .idle, "the window closed and the take stopped")
        await until("the device is free") { hal.isFree }
    }

    /// Fix check: Stop and Quit during a take stops the take; the refused draft goes.
    @Test func quitDuringATakeDropsTheRefusedDraft() async throws {
        let hal = CountingHAL()
        let (model, studio) = try await refusedNumberInATake(hal)
        app.confirmQuit = { _, _, _ in true }
        #expect(app.applicationShouldTerminate(NSApp) == .terminateLater)
        await until("Quit stops the take") { studio.transport == .idle }
        #expect(model.episodeDraft == nil)
        await model.close()
        await until("the device is free") { hal.isFree }
    }

    /// Fix check: Quit with two windows stops at the window with the refused draft and keeps the
    /// typed text of the other window.
    @Test func quitStopsAtTheWindowWithTheRefusedDraft() async throws {
        let (a, studioA, windowA, _) = try await open(try await package("a"))
        let (b, _, windowB, _) = try await open(try await package("b"))
        for (model, window) in [(a, windowA), (b, windowB)] {
            model.showEpisodeInfo()
            _ = try await episodeFields(window)
        }
        a.typeEpisode("Title A", in: .title)
        b.typeEpisode("0", in: .number)
        b.commitEpisode()
        #expect(app.applicationShouldTerminate(NSApp) == .terminateCancel && !app.terminating)
        #expect(b.episodeDraft?.refused == true && b.inspectorTab == .episode)
        let saved = studioA.session.episode.title?.text == "Title A" && a.episodeDraft == nil
        #expect(saved || a.episodeDraft?.text == "Title A", "the text of window a stays")
        b.episodeDraft = nil
        await a.close()
        await b.close()
    }
}
