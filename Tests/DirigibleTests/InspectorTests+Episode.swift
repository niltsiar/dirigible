import AppKit
import DirigibleCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleTimeline

/// The Episode pane (decision 0045, criteria C9 and C10) in the window of `InspectorTests`.
extension InspectorTests {
    /// The editable fields of the Episode pane, top first: Title is the first.
    func episodeFields(_ window: NSWindow) async throws -> [NSTextField] {
        await until(limit: .seconds(10), "the Episode pane shows its fields") { shownFields(window).count >= 8 }
        return shownFields(window)
    }

    /// Waits until Title of the pane has the focus: the field editor edits the first field. A field
    /// of a parallel suite can take the shared field editor; the window is then its own first
    /// responder (`focusedNameEditor(in:)`), as in `theItemTogglesThePaneAndKeepsThePreference`.
    func waitForTitleFocus(_ model: SessionWindow, _ window: NSWindow) async throws {
        let title = try await episodeFields(window)[0]
        await until(limit: .seconds(10), "the focus goes to Title") {
            model.episodeFocus == .title && (focusedField(window) === title || window.firstResponder === window)
        }
    }

    /// C9: File > Episode Info… shows the Episode pane with the focus in Title, from the pane
    /// hidden, the Clip tab with the focus in a clip field, the lanes, and Notes.
    @Test func episodeInfoShowsTheEpisodePaneWithTheFocusInTitle() async throws {
        let (model, studio, window, view) = try await open(try await package(), shown: false)
        model.run(.episodeInfo)
        #expect(model.showsInspector && model.inspectorTab == .episode, "from a hidden pane")
        try await waitForTitleFocus(model, window)

        model.inspectorTab = .clip
        model.timeline.marks = overA
        let clipFields = try await paneFields(window)
        await focus(clipFields[0], window, model)
        model.run(.episodeInfo)
        #expect(model.inspectorTab == .episode, "from the Clip tab")
        try await waitForTitleFocus(model, window)

        #expect(window.makeFirstResponder(view.lanes))
        model.run(.episodeInfo)
        try await waitForTitleFocus(model, window)

        let notes = try #require(textViews(in: window.contentView).first { !$0.isFieldEditor })
        #expect(window.makeFirstResponder(notes))
        await until("Notes has the focus") { model.episodeFocus == .notes }
        model.run(.episodeInfo)
        try await waitForTitleFocus(model, window)
        #expect(!studio.canUndo, "no edit")
        await model.close()
    }

    /// Item 1398: File > Episode Info from Notes puts the focus in Title also when the first focus
    /// move ends at once and the pane never sees Title.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func episodeInfoKeepsItsFocusRequestUntilTitleHasTheFocus() async throws {
        let (model, _, window, _) = try await open(try await package())
        model.showEpisodeInfo()
        try await waitForTitleFocus(model, window)
        let notes = try #require(textViews(in: window.contentView).first { !$0.isFieldEditor })
        #expect(window.makeFirstResponder(notes))
        await until("Notes has the focus") { model.episodeFocus == .notes }

        let (observation, ended) = endNextFieldEdit(in: window)
        model.run(.episodeInfo)
        await until(limit: .seconds(10), "the first focus move ends") { ended() }
        let title = try await episodeFields(window)[0]
        await until(limit: .seconds(10), "Title edits with the focus") {
            model.episodeFocus == .title && focusedField(window) === title
        }
        observation.invalidate()
        await model.close()
    }

    func textViews(in view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        return ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap { textViews(in: $0) }
    }

    /// C9, C10: a commit is one undo entry and draws the lanes 0 times; a gain commit draws them.
    @Test func anEpisodeCommitIsOneUndoEntryAndDrawsNoLanes() async throws {
        let (model, studio, window, view) = try await open(try await package())
        model.showEpisodeInfo()
        _ = try await episodeFields(window)
        model.typeEpisode("Episode 1", in: .title)
        drawNow(window)
        var draws = view.lanes.draws
        model.commitEpisode()
        await until("the lanes take the session") { view.lanes.inputs?.session == studio.session }
        drawNow(window)
        #expect(view.lanes.draws == draws, "an episode commit drew the lanes")
        #expect(studio.session.episode.title?.text == "Episode 1")

        model.inspectorTab = .clip
        model.timeline.marks = overA
        _ = try await paneFields(window)
        drawNow(window)
        draws = view.lanes.draws
        model.type("-3", in: .clip(.gain))
        model.commitInspector()
        await until("the control: a gain commit draws the lanes") {
            drawNow(window)
            return view.lanes.draws > draws
        }
        #expect(undoAll(model, studio) == 2, "one entry each")
        await model.close()
    }

    /// C9, code gate 1 item 2: a bad value beeps, keeps the draft, and shows the rule of the
    /// field. A corrected text saves. Esc puts back the shown text.
    @Test func aBadEpisodeValueKeepsTheDraftAndEscPutsBackTheText() async throws {
        let (model, studio, window, view) = try await open(try await package())
        var beeps = 0
        model.beep = { beeps += 1 }
        model.showEpisodeInfo()
        let fields = try await episodeFields(window)
        let refused: [(EpisodeField, String, L10n)] = [
            (.number, "0", .errorEpisodeNumber), (.feedURL, "ftp://a.b", .errorEpisodeURL),
            (.date, "2026-02-30", .errorEpisodeDate),
        ]
        for (field, text, message) in refused {
            model.typeEpisode(text, in: field)
            model.commitEpisode()
            #expect(model.episodeDraft == EpisodeDraft(field: field, shown: "", text: text, refused: true))
            #expect(EpisodeInspector.refusal(field) == message)
            model.episodeDraft = nil
        }
        #expect(beeps == 3 && studio.session.episode.isEmpty && !studio.canUndo, "beeps: \(beeps)")
        model.typeEpisode("0", in: .number)
        model.commitEpisode()
        model.typeEpisode("7", in: .number)
        #expect(model.episodeDraft?.refused == false, "a new key removes the message")
        model.commitEpisode()
        #expect(studio.session.episode.number?.value == 7 && model.episodeDraft == nil)
        model.undo()
        await until("the undo ends") { !studio.canUndo }

        try await waitForTitleFocus(model, window)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("Typed", replacementRange: editor.selectedRange())
        #expect(model.episodeDraft?.text == "Typed")
        press("\u{1b}", 53, window)
        await until("Esc gives the focus to the lanes") { window.firstResponder === view.lanes }
        #expect(model.episodeDraft == nil && !studio.canUndo, "Esc made no edit")
        #expect(fields[0].stringValue == "", "Title shows its old text: \(fields[0].stringValue)")
        await model.close()
    }

    /// C10, gate item 1: the lanes keep the whole session, so a trim commit from their session
    /// keeps the episode and is one undo entry.
    @Test func aTrimWithAnEpisodeKeepsTheEpisode() async throws {
        let (model, studio, window, view) = try await open(try await package())
        model.showEpisodeInfo()
        _ = try await episodeFields(window)
        model.typeEpisode("Episode 1", in: .title)
        model.commitEpisode()
        let episode = studio.session.episode
        await until("the lanes take the episode") { view.lanes.inputs?.session == studio.session }
        let base = try #require(view.lanes.inputs?.session)
        var result = base
        try result.trim("A", to: 12_000..<48_000)
        model.apply([.commit(GestureCommit(base: base, result: result, selection: nil, marker: nil, ripple: false))])
        #expect(studio.session.clip("A")?.clip.start == 12_000, "the trim is in the session")
        #expect(studio.session.episode == episode && !episode.isEmpty, "the trim keeps the episode")
        #expect(undoAll(model, studio) == 2, "the trim is one entry")
        await model.close()
    }

    /// C9: Choose… or a drop copies the image as one entry; Remove clears it as one entry and
    /// keeps the file.
    @Test func artworkSetAndRemoveAreOneUndoEntryEach() async throws {
        let (model, studio, _, _) = try await open(try await package())
        model.showEpisodeInfo()
        let image = folder.url.appending(path: "cover.png")
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let destination = try #require(
            CGImageDestinationCreateWithURL(image as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))

        model.setArtwork(image)
        await model.importJob?.task?.value
        let name = try #require(studio.session.episode.artwork)
        model.removeArtwork()
        #expect(studio.session.episode.artwork == nil)
        #expect(FileManager.default.fileExists(atPath: studio.url.appending(path: name.path).path), "the file stays")
        #expect(undoAll(model, studio) == 2, "one entry each")
        await model.close()
    }

    /// Code gate item 1: a close saves a typed episode field.
    @Test func aTypedTitleIsSavedAtClose() async throws {
        let url = try await package()
        let (model, _, _, _) = try await open(url)
        model.showEpisodeInfo()
        model.typeEpisode("Typed title", in: .title)
        await model.close()
        #expect(try Session(contentsOf: url).episode.title?.text == "Typed title")
    }

    /// Code gate item 1: a tab change commits the typed text of both panes.
    @Test func aTabChangeKeepsTheTypedText() async throws {
        let (model, studio, window, _) = try await open(try await package())
        model.showEpisodeInfo()
        _ = try await episodeFields(window)
        model.typeEpisode("Typed title", in: .title)
        model.selectInspectorTab(.clip)
        #expect(studio.session.episode.title?.text == "Typed title" && model.inspectorTab == .clip)

        model.timeline.marks = overA
        _ = try await paneFields(window)
        model.type("-3", in: .clip(.gain))
        model.selectInspectorTab(.episode)
        #expect(gain(studio, "A") == -3 && model.inspectorTab == .episode)
        await model.close()
    }
}
