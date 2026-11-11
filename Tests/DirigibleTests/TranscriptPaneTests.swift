import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The Transcript tab of the inspector in a real session window (run transcript-1, landing 2,
/// criteria P1, P12, P17, P19). Track t1 "Host" has three paragraphs: "Hello there" at 1 s,
/// "Second part" at 6 s, and "Third" at 11 s of a 20 s clip.
@Suite(.serialized) @MainActor struct TranscriptPaneTests {
    let folder: TemporaryFolder
    let defaults: UserDefaults
    let suite = "TranscriptPaneTests.\(UUID().uuidString)"
    let app: AppDelegate

    init() throws {
        folder = try TemporaryFolder()
        defaults = try #require(UserDefaults(suiteName: suite))
        app = AppDelegate(recordings: nil, defaults: defaults)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// The start frame of "Second" and the start of the gap after "part".
    static let second: Frames = 288_000
    static let afterSecond: Frames = 400_000

    /// A package with the track and the clip, and with the transcript when `spoken` is true.
    func package(
        spoken: Bool = true, name: String = "a", trackName: String = "Host",
        words custom: [(Double, Double, String)]? = nil
    ) async throws -> URL {
        let url = folder.url.appending(path: "\(name).dirigible")
        try await Task.detached {
            try Session.create(at: url, sampleRate: 48_000)
            var session = Session(sampleRate: 48_000)
            try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 960_000))
            try session.addTrack("t1", name: trackName, layout: .mono)
            try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
            try session.place(Clip(id: "A", file: "f1", start: 0, offset: 0, length: 960_000), on: "t1")
            if spoken {
                let words: [(Double, Double, String)] =
                    custom ?? [
                        (1, 1.5, "Hello"), (1.5, 2, "there"), (6, 6.5, "Second"), (6.5, 7, "part"), (11, 11.5, "Third"),
                    ]
                let json =
                    #"{"words":["#
                    + words.map { #"{"word":" \#($0.2)","start":\#($0.0),"end":\#($0.1)}"# }
                    .joined(separator: ",") + "]}"
                try session.importTranscript(TranscriptFile(data: Data(json.utf8)), name: "Host", track: "t1", at: 0)
            }
            try session.write(to: url)
        }.value
        return url
    }

    func open(_ url: URL, shown: Bool = false) async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let opened = try await openLanes(app, url)
        #expect(opened.2.makeFirstResponder(opened.3.lanes))
        if shown && !opened.0.showsInspector { opened.0.toggleInspector() }
        return opened
    }

    /// The text view of the pane, once the tab shows it.
    func pane(_ window: NSWindow) -> TranscriptTextView? { Self.find(window.contentView) }

    static func find(_ view: NSView?) -> TranscriptTextView? {
        guard let view else { return nil }
        if let found = view as? TranscriptTextView { return found }
        return view.subviews.lazy.compactMap { find($0) }.first
    }

    func waitForPane(_ window: NSWindow, focused: Bool = true) async throws -> TranscriptTextView {
        await until(limit: .seconds(10), "the pane shows and takes the focus") {
            window.contentView?.layoutSubtreeIfNeeded()
            guard let pane = pane(window), pane.shownRevision == pane.builtRevision else { return false }
            return !focused || window.firstResponder === pane
        }
        return try #require(pane(window))
    }

    /// Types `text` into the Title field of the Episode pane as a person does, so the field editor
    /// holds it: a field that the tab change removes sends its own text. The field editor is one
    /// object for all windows of the test process, so the wait gives the focus back to the field.
    func type(_ text: String, intoTitleOf window: NSWindow, _ model: SessionWindow) async throws {
        func fields(_ view: NSView?) -> [NSTextField] {
            guard let view else { return [] }
            return ((view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []) + view.subviews.flatMap(fields)
        }
        func title() -> NSTextField? {
            window.contentView?.layoutSubtreeIfNeeded()
            let edge = window.contentLayoutRect.width - InspectorWidth.standard.points
            return fields(window.contentView).filter { $0.convert($0.bounds, to: nil).minX >= edge }
                .max { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
        }
        await until("the Title field has the focus") {
            guard let field = title() else { return false }
            if (window.firstResponder as? NSTextView)?.delegate !== field { window.makeFirstResponder(field) }
            return model.episodeFocus == .title && (window.firstResponder as? NSTextView)?.delegate === field
        }
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    func seek(_ studio: Studio, to frame: Frames) async {
        await studio.perform(.seek(.frame(frame)))
        await until("the playhead is at the frame") { studio.playhead == frame }
    }

    // MARK: P1

    /// P1, states (a) to (d): the menu command shows the tab, shows the inspector, and focuses the
    /// pane. A refused Episode draft keeps the Episode tab, with a beep.
    @Test func showTranscriptFromEachState() async throws {
        // (a) the inspector hidden, the focus in the lanes.
        let (model, studio, window, view) = try await open(try await package())
        model.showTranscript()
        #expect(model.showsInspector && model.inspectorTab == .transcript, "(a)")
        _ = try await waitForPane(window)

        // (b) the inspector shown at each other tab, with the focus in the lanes.
        for tab in [InspectorTab.clip, .episode, .marker] {
            model.inspectorTab = tab
            #expect(window.makeFirstResponder(view.lanes))
            model.showTranscript()
            #expect(model.inspectorTab == .transcript, "(b) \(tab)")
            _ = try await waitForPane(window)
        }

        // (c) the focus in an Episode field with valid typed text: the draft commits first.
        model.showEpisodeInfo()
        try await type("Episode 1", intoTitleOf: window, model)
        model.showTranscript()
        #expect(model.inspectorTab == .transcript, "(c)")
        _ = try await waitForPane(window)
        #expect(studio.session.episode.title?.text == "Episode 1", "(c) the draft committed")
        // The field goes with the tab change and sends its text: no new draft comes from that.
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.episodeDraft == nil, "(c) no draft is left")

        // (d) a refused draft: the Episode tab stays, with a beep.
        var beeps = 0
        model.beep = { beeps += 1 }
        model.showEpisodeInfo()
        await until("the Episode title has the focus") { model.episodeFocus == .title }
        model.typeEpisode("0", in: .number)
        model.showTranscript()
        #expect(model.inspectorTab == .episode && model.episodeDraft?.refused == true, "(d)")
        #expect(beeps >= 1, "(d) a beep")
        await model.close()
    }

    /// P1: the insertion point is a collapsed selection at the first unit of the current paragraph.
    @Test func showTranscriptPutsTheCaretInTheCurrentParagraph() async throws {
        let (model, studio, window, view) = try await open(try await package())
        let cases: [(frame: Frames, word: String)] = [
            (Self.second + 1_000, "Second"), (Self.afterSecond, "Second"), (10, "Hello"), (528_000, "Third"),
        ]
        for (frame, word) in cases {
            await seek(studio, to: frame)
            model.inspectorTab = .clip
            #expect(window.makeFirstResponder(view.lanes))
            model.showTranscript()
            let pane = try await waitForPane(window)
            let expected = (pane.string as NSString).range(of: word).location
            #expect(pane.selectedRange() == NSRange(location: expected, length: 0), "playhead \(frame)")
        }
        await model.close()
    }

    /// P1: a click on the Transcript segment keeps the focus in the lanes, and a focus in an
    /// Episode field goes to the lanes (the draft commits first).
    @Test func tabClickKeepsTheFocus() async throws {
        let (model, studio, window, view) = try await open(try await package(), shown: true)
        model.selectInspectorTab(.transcript)
        _ = try await waitForPane(window, focused: false)
        #expect(window.firstResponder === view.lanes, "from the lanes")

        model.showEpisodeInfo()
        try await type("Episode 2", intoTitleOf: window, model)
        model.selectInspectorTab(.transcript)
        let pane = try await waitForPane(window, focused: false)
        await until("the lanes have the focus") { window.firstResponder === view.lanes }
        #expect(window.firstResponder !== pane)
        #expect(studio.session.episode.title?.text == "Episode 2")
        await model.close()
    }

    /// P1: with the Transcript tab shown, the item hides the inspector, and the focus goes to the lanes.
    @Test func hideTranscriptFocusesTheLanes() async throws {
        let (model, _, window, view) = try await open(try await package())
        model.showTranscript()
        _ = try await waitForPane(window)
        #expect(app.transcriptItem(for: model).title == .menuViewTranscriptHide)
        model.toggleTranscript()
        #expect(!model.showsInspector)
        #expect(window.firstResponder === view.lanes)
        #expect(app.transcriptItem(for: model).title == .menuViewTranscriptShow)
        await model.close()
    }

    @Test func showTranscriptIsOffWithNoSession() {
        #expect(app.transcriptItem(for: nil).enabled == false)
        let opening = SessionWindow(url: folder.url, recordings: nil, app: app)
        #expect(opening.studio == nil && !app.transcriptItem(for: opening).enabled, "a window that is opening")
    }

    // MARK: P12

    /// P12: a transcript whose file is gone shows the line above the text. The other units show.
    @Test func notLoadedLineShows() async throws {
        let url = try await package()
        let files = try FileManager.default.contentsOfDirectory(
            at: url.appending(path: "Transcripts"), includingPropertiesForKeys: nil)
        for file in files { try FileManager.default.removeItem(at: file) }
        let (model, _, window, _) = try await open(url)
        model.showTranscript()
        let pane = try await waitForPane(window)
        let line = L10n.transcriptNotLoaded.format(1, "Host")
        #expect(pane.string.hasPrefix(line), "\(pane.string)")
        await model.close()
    }

    // MARK: P17

    /// P17: a header with a name of 80 characters is one line fragment at the least width of the tab
    /// (320 pt, P20) and at 400 pt.
    @Test func longTrackNameStaysOnOneLine() async throws {
        let name = String(repeating: "Interview with a very long track name ", count: 3).prefix(80)
        let (model, _, window, _) = try await open(try await package(trackName: String(name)))
        model.showTranscript()
        let pane = try await waitForPane(window)
        for width in [320.0, 400.0] {
            model.inspectorWidth = InspectorWidth(width)
            model.widenForPanes()
            window.contentView?.layoutSubtreeIfNeeded()
            // The column takes the divider and the two paddings of 12 pt.
            await until("the pane has the width") {
                window.contentView?.layoutSubtreeIfNeeded()
                return abs((pane.enclosingScrollView?.frame.width ?? 0) - (width - 25)) < 3
            }
            #expect(pane.headerLineFragments() == [1, 1, 1], "\(width) pt")
        }
        await model.close()
    }

    // MARK: P19

    /// P19: a selection in the lanes keeps the Transcript tab: a click on a clip, a clip set, a range
    /// drag, a click on a marker flag, and Select All.
    @Test func laneSelectionKeepsTheTab() async throws {
        let (model, _, window, _) = try await open(try await package(), shown: true)
        model.selectInspectorTab(.transcript)
        _ = try await waitForPane(window, focused: false)
        let range = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])
        let selections: [(String, [GestureEffect])] = [
            ("a click on a clip", [.selection(.clips(ClipSet("A")))]),
            ("a clip set", [.selection(.clips(try #require(ClipSet(["A", "B"]))))]),
            ("a range drag", [.selection(.range(range))]),
            ("a click on a marker flag", [.currentMarker("m1")]),
        ]
        for (name, effects) in selections {
            model.apply(effects)
            #expect(model.inspectorTab == .transcript, "\(name)")
        }
        model.run(.selectAll)
        #expect(model.inspectorTab == .transcript, "Select All")
        await model.close()
    }

    // MARK: P20

    /// P20: the Transcript tab shows the inspector at least 320 pt wide, and widens the window for
    /// it. The saved width stays.
    @Test func transcriptTabSetsTheMinimumWidth() async throws {
        let (model, _, window, _) = try await open(try await package())
        func contentWidth() -> Double { Double(window.contentLayoutRect.width) }
        model.inspectorWidth = InspectorWidth(240)

        // (a) Show Transcript with a saved width of 240 pt.
        model.showTranscript()
        #expect(model.shownInspectorWidth == 320, "(a)")
        #expect(contentWidth() >= SessionView.minWidth + 320, "(a) the window widened")
        model.selectInspectorTab(.clip)
        #expect(model.shownInspectorWidth == 240, "(a) the Clip tab after it")

        // (b) A click on the Transcript tab from the Clip tab.
        model.selectInspectorTab(.transcript)
        #expect(model.shownInspectorWidth == 320, "(b)")

        // (c) A saved width of 360 pt.
        model.inspectorWidth = InspectorWidth(360)
        #expect(model.shownInspectorWidth == 360, "(c)")

        // (d) A window with no room for the lanes minimum plus 320 pt.
        model.inspectorWidth = InspectorWidth(240)
        var frame = window.frame
        frame.size.width -= max(0, contentWidth() - (SessionView.minWidth + 240))
        window.setFrame(frame, display: true)
        model.selectInspectorTab(.clip)
        model.selectInspectorTab(.transcript)
        #expect(contentWidth() >= SessionView.minWidth + 320, "(d)")

        // (e) A step down from a saved 240 pt stays at 240 pt: a step never moves the saved width up.
        model.stepInspector(by: -70)
        #expect(model.shownInspectorWidth == 320, "(e)")
        #expect(model.inspectorWidth.points == 240, "(e) the saved width does not rise")
        await model.close()
    }

    // MARK: P22

    static func segmented(_ view: NSView?) -> NSSegmentedControl? {
        guard let view else { return nil }
        if let found = view as? NSSegmentedControl { return found }
        return view.subviews.lazy.compactMap { segmented($0) }.first
    }

    /// P22: the picker of five symbols fits the narrowest inspector (240 pt minus 2 x 12 pt of
    /// padding), and each segment has its tab title as its help tag (the accessibility label is the same text).
    @Test func tabPickerFitsTheNarrowestInspector() async throws {
        let (model, _, window, _) = try await open(try await package(), shown: true)
        var found: NSSegmentedControl?
        await until("the picker shows") {
            window.contentView?.layoutSubtreeIfNeeded()
            found = Self.segmented(window.contentView)
            return found != nil
        }
        let picker = try #require(found)
        #expect(picker.segmentCount == 5)
        #expect(picker.fittingSize.width <= 216, "\(picker.fittingSize.width) pt")
        let cell = try #require(picker.cell as? NSSegmentedCell)
        let labels = (0..<picker.segmentCount).map { cell.toolTip(forSegment: $0) }
        #expect(labels == InspectorTab.allCases.map { $0.title.text }, "\(labels)")
        await model.close()
    }

    // MARK: P4b, P14

    /// P4b: the pane builds its text only when the session revision changes. A play tick and a seek
    /// build nothing, a gain edit builds once and replaces no storage, because no unit changes, and
    /// the ripple delete of "Second part" (two units gone, the later header moved) replaces it once.
    @Test func buildsOnlyOnANewRevision() async throws {
        let (model, studio, window, _) = try await open(try await package())
        model.showTranscript()
        let pane = try await waitForPane(window)
        let (builds, replacements) = (pane.builds, pane.replacements)
        #expect(builds >= 1 && replacements == 1, "the first build fills the storage")
        for n in 1...20 { await seek(studio, to: Frames(n * 1_000)) }
        #expect(pane.builds == builds, "a seek builds nothing")
        try studio.edit(ripple: false) { s throws(SessionError) in try s.setGains(["A": Gain(dB: -3)!]) }
        await until("the pane applies the new revision") {
            pane.builds == builds + 1 && pane.shownRevision == pane.builtRevision
        }
        #expect(pane.replacements == replacements, "a gain edit replaces no storage")
        try studio.edit(ripple: true) { s throws(SessionError) in
            try s.rippleDelete(288_000..<336_000, on: ["t1"], naming: [])
        }
        await until("the pane applies again") { pane.builds == builds + 2 && pane.shownRevision == pane.builtRevision }
        #expect(pane.replacements == replacements + 1, "a ripple delete replaces the storage once")
        #expect(!pane.string.contains("Second"), "the cut words are gone")
        await model.close()
    }

    /// P14: with the pane focused, the window takes the keys as with the lanes focused: the
    /// transport keys act, and Esc empties the Marks.
    @Test func escapeReachesTheWindow() async throws {
        let (model, _, window, _) = try await open(try await package())
        model.showTranscript()
        _ = try await waitForPane(window)
        #expect(takesTransportKeys(window), "a plain transport key acts with the pane focused")
        model.timeline.selection = .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        (window as? UndoRoutingWindow)?.cancelOperation(nil)
        #expect(model.timeline.selection == .none, "Esc empties the Marks")
        await model.close()
    }
}

extension TranscriptTextView {
    /// The count of line fragments of each header paragraph, in text order.
    func headerLineFragments() -> [Int] {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return [] }
        layout.ensureLayout(for: content.documentRange)
        var counts: [Int] = []
        layout.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout]) {
            fragment in
            if let paragraph = fragment.textElement as? NSTextParagraph,
                paragraph.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                    == TranscriptTextView.headerFont
            {
                counts.append(fragment.textLineFragments.count)
            }
            return true
        }
        return counts
    }
}
