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
}
