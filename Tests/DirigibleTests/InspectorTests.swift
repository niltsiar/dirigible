import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The clip inspector in a real session window (run 11b-2, criteria W1 to W7). Track t1 has the
/// 1 s clips A (0 s), B (2 s), and C (4 s) of a 10 s file f1 that is not on disk. The expected
/// texts come from the formatter of the pane: the runner has the number format of the Mac.
@Suite(.serialized) @MainActor struct InspectorTests {
    let folder: TemporaryFolder
    let defaults: UserDefaults
    let suite = "InspectorTests.\(UUID().uuidString)"
    let app: AppDelegate
    let hal = CountingHAL()
    /// The Marks over A, over B, and over A, B, and C.
    let overA = Marks(inPoint: 12_000, outPoint: 24_000, tracks: ["t1"])
    let overB = Marks(inPoint: 108_000, outPoint: 120_000, tracks: ["t1"])
    let overAll = Marks(inPoint: 0, outPoint: 480_000, tracks: ["t1"])

    init() throws {
        folder = try TemporaryFolder()
        defaults = try #require(UserDefaults(suiteName: suite))
        app = AppDelegate(recordings: nil, defaults: defaults)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// A package with A, B, and C at `gains` (dB) and `fades` on t1, routed to `device`.
    func package(
        _ name: String = "a", gains: [ClipID: Double] = [:], fades: [ClipID: Fades] = [:], device: String = "mic"
    ) async throws -> URL {
        let url = folder.url.appending(path: "\(name).dirigible")
        try await Task.detached {
            try Session.create(at: url, sampleRate: 48_000)
            var session = Session(sampleRate: 48_000)
            try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 480_000))
            try session.addTrack("t1", name: "T1", layout: .mono)
            try session.setRoute(Route.device(uid: device, channels: .mono(1)), track: "t1")
            for (id, start) in [("A", 0), ("B", 96_000), ("C", 192_000)] as [(ClipID, Frames)] {
                try session.place(Clip(id: id, file: "f1", start: start, offset: start, length: 48_000), on: "t1")
            }
            try session.setGains(gains.mapValues { Gain(dB: $0)! })
            try session.setFades(fades)
            try session.write(to: url)
        }.value
        return url
    }

    /// A window with the lanes as the first responder and the pane shown.
    func open(_ url: URL, shown: Bool = true) async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let opened = try await openLanes(app, url)
        #expect(opened.2.makeFirstResponder(opened.3.lanes))
        if shown && !opened.0.showsInspector { opened.0.toggleInspector() }
        return opened
    }

    /// The editable text fields of the pane, top first: Gain, Fade In, Fade Out.
    func shownFields(_ window: NSWindow) -> [NSTextField] {
        window.contentView?.layoutSubtreeIfNeeded()
        let edge = window.contentLayoutRect.width - InspectorView.width
        return textFields(in: window.contentView)
            .filter { $0.convert($0.bounds, to: nil).minX >= edge }
            .sorted { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }
    }

    func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
        return own + view.subviews.flatMap { textFields(in: $0) }
    }

    /// The three fields, once the pane shows them.
    func paneFields(_ window: NSWindow) async throws -> [NSTextField] {
        await until(limit: .seconds(10), "the pane shows its fields") { shownFields(window).count == 3 }
        return shownFields(window)
    }

    /// Focuses `field` and waits until the pane has the focus, as a person who types does. The
    /// SwiftUI field editor is one object for all windows of the test process, and a field of a
    /// parallel suite can take it (`focusedNameEditor(in:)`), so the wait gives the focus back.
    func focus(_ field: NSTextField, _ window: NSWindow, _ model: SessionWindow) async {
        await until("the pane takes the focus") {
            if focusedField(window) !== field { window.makeFirstResponder(field) }
            return model.inspectorFocus != nil && focusedField(window) === field
        }
    }

    /// Focuses `field` and replaces its text with `text`, as typing does. No await comes between
    /// the focus check and the keys.
    func type(_ text: String, in field: NSTextField, _ window: NSWindow, _ model: SessionWindow) async throws {
        await focus(field, window, model)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    /// A key-down and key-up as the keyboard sends them: Return 36, Tab 48, Esc 53.
    func press(_ characters: String, _ code: UInt16, _ window: NSWindow) {
        let down = key(.keyDown, characters, code: code, in: window)
        if !window.performKeyEquivalent(with: down) { window.sendEvent(down) }
        window.sendEvent(key(.keyUp, characters, code: code, in: window))
    }

    /// Undoes every entry and returns their count.
    func undoAll(_ model: SessionWindow, _ studio: Studio) -> Int {
        var count = 0
        while studio.canUndo && count < 10 {
            model.undo()
            count += 1
        }
        return count
    }

    func gain(_ studio: Studio, _ clip: ClipID) -> Double? { studio.session.clip(clip)?.clip.gain.dB }
    func decibels(_ dB: Double) -> String { ReadoutLayer.decibels(Gain(dB: dB)!, locale: .current) }

    /// The editor of `window` with the focus in a field of the pane, or nil.
    func focusedField(_ window: NSWindow) -> NSTextField? {
        (window.firstResponder as? NSTextView)?.delegate as? NSTextField
    }

    // MARK: W5

    /// W5: the commit sets the clips of the draft, not the clips of the Marks at the focus loss.
    @Test func aCommitSetsTheClipsOfTheDraft() async throws {
        let (model, studio, window, view) = try await open(try await package())
        let before = studio.session
        model.timeline.marks = overA
        let fields = try await paneFields(window)
        try await type("-3", in: fields[0], window, model)
        await until("the typed text is a draft") { model.inspectorDraft?.text == "-3" }

        model.timeline.marks = overB
        #expect(window.makeFirstResponder(view.lanes))

        await until("the focus loss commits") { gain(studio, "A") == -3 }
        #expect(gain(studio, "B") == 0, "B: \(String(describing: gain(studio, "B")))")
        #expect(undoAll(model, studio) == 1 && studio.session == before, "one undo entry")
        await model.close()
    }

    /// W5: a lane mouse-down commits the draft first (`commitNames`), so a gain drag on B after a
    /// typed gain for A gives two undo entries.
    @Test func aLaneGestureCommitsTheDraftFirst() async throws {
        let (model, studio, window, view) = try await open(try await package())
        let before = studio.session
        model.timeline.marks = overA
        let fields = try await paneFields(window)
        try await type("-3", in: fields[0], window, model)
        await until("the typed text is a draft") { model.inspectorDraft?.text == "-3" }

        let scale = try #require(view.lanes.inputs?.scale.framesPerPoint)
        let x = 120_000 / scale
        for (type, y) in [(NSEvent.EventType.leftMouseDown, 3.0), (.leftMouseDragged, 13), (.leftMouseUp, 13)] {
            let event = try mouse(type, NSPoint(x: x, y: y), in: view)
            switch type {
            case .leftMouseDown: view.lanes.mouseDown(with: event)
            case .leftMouseDragged: view.lanes.mouseDragged(with: event)
            default: view.lanes.mouseUp(with: event)
            }
        }

        #expect(gain(studio, "A") == -3, "A: \(String(describing: gain(studio, "A")))")
        #expect(
            gain(studio, "B").map { $0 < 0 } == true, "B has the drag gain: \(String(describing: gain(studio, "B")))")
        #expect(undoAll(model, studio) == 2 && studio.session == before, "two undo entries")
        await model.close()
    }

    // MARK: W4

    /// W4: Return, Tab, a focus loss, and Esc each commit or revert once; a refused number beeps.
    @Test func eachKeyCommitsOrRevertsOnce() async throws {
        let (model, studio, window, view) = try await open(try await package())
        let before = studio.session
        var beeps = 0
        model.beep = { beeps += 1 }
        model.timeline.marks = overA
        var fields = try await paneFields(window)

        try await type("-3", in: fields[0], window, model)
        press("\r", 36, window)
        #expect(gain(studio, "A") == -3, "Return: \(String(describing: gain(studio, "A")))")
        #expect(window.firstResponder === view.lanes, "Return gives the focus to the lanes")
        #expect(undoAll(model, studio) == 1 && studio.session == before, "Return: one entry")
        // The field ends its editing after the commit and sends its text again. That text must not
        // become a new draft, which shows the old value after an undo (on-screen check, verify/).
        try await Task.sleep(for: .milliseconds(200))
        #expect(
            model.inspectorDraft == nil, "Return: a draft after the commit: \(String(describing: model.inspectorDraft))"
        )
        #expect(shownFields(window).first?.stringValue == decibels(0), "Return and Undo: the field shows the value")

        fields = try await paneFields(window)
        try await type("-3", in: fields[0], window, model)
        press("\t", 48, window)
        await until("Tab commits") { gain(studio, "A") == -3 }
        #expect(focusedField(window) === fields[1], "Tab goes to Fade In")
        #expect(window.makeFirstResponder(view.lanes))
        #expect(undoAll(model, studio) == 1 && studio.session == before, "Tab: one entry")

        fields = try await paneFields(window)
        try await type("-3", in: fields[0], window, model)
        #expect(window.makeFirstResponder(view.lanes))
        await until("a focus loss commits") { gain(studio, "A") == -3 }
        #expect(undoAll(model, studio) == 1 && studio.session == before, "focus loss: one entry")

        fields = try await paneFields(window)
        try await type("-3", in: fields[0], window, model)
        press("\u{1b}", 53, window)
        try await Task.sleep(for: .milliseconds(200))
        #expect(window.firstResponder === view.lanes, "Esc gives the focus to the lanes")
        #expect(studio.session == before && !studio.canUndo, "Esc: no edit")
        await until("Esc puts back the shown text") { shownFields(window).first?.stringValue == decibels(0) }

        fields = try await paneFields(window)
        try await type("abc", in: fields[0], window, model)
        press("\r", 36, window)
        #expect(beeps == 1, "abc: \(beeps) beeps")
        await until("abc puts back the shown text") { shownFields(window).first?.stringValue == decibels(0) }

        fields = try await paneFields(window)
        try await type("1.500", in: fields[1], window, model)
        press("\r", 36, window)
        #expect(beeps == 2, "1.500 in Fade In: \(beeps) beeps")
        await until("1.500 puts back the shown text") { shownFields(window).dropFirst().first?.stringValue == "0" }
        #expect(studio.session == before && !studio.canUndo, "a refused number: no edit")
        await model.close()
    }

    /// W4: a field with no typing makes no edit and no beep: -7.37 dB shows -7.4, and a Tab does
    /// not round it; a Tab through Mixed and Return in an empty Mixed field do nothing.
    @Test func aFieldWithNoTypingMakesNoEdit() async throws {
        let (model, studio, window, view) = try await open(try await package(gains: ["A": -7.37, "B": -6]))
        var beeps = 0
        model.beep = { beeps += 1 }
        model.timeline.marks = overA
        var fields = try await paneFields(window)
        #expect(fields[0].stringValue == decibels(-7.37))
        await focus(fields[0], window, model)
        press("\t", 48, window)
        await until("Tab goes to Fade In") { focusedField(window) === fields[1] }
        #expect(window.makeFirstResponder(view.lanes))
        #expect(gain(studio, "A") == -7.37 && !studio.canUndo, "a Tab with no typing: no edit")

        model.timeline.marks = Marks(inPoint: 12_000, outPoint: 120_000, tracks: ["t1"])
        await until("A and B show Mixed") { shownFields(window).first?.stringValue == "" }
        fields = shownFields(window)
        await focus(fields[0], window, model)
        press("\t", 48, window)
        await until("Tab goes to Fade In") { focusedField(window) === fields[1] }
        await focus(fields[0], window, model)
        press("\r", 36, window)
        try await Task.sleep(for: .milliseconds(200))
        #expect(beeps == 0 && !studio.canUndo, "Mixed: \(beeps) beeps")
        await model.close()
    }

    // MARK: W6

    /// W6: Select All on mixed gains, -6, and Return: one edit, and Undo gives back the gains.
    @Test func aTypedGainOnSelectAllIsOneEdit() async throws {
        let (model, studio, window, _) = try await open(try await package(gains: ["A": -6, "C": 3]))
        let before = studio.session
        app.timeline(.selectAll, event: nil, in: window)
        await until("Select All shows Mixed") { shownFields(window).first.map { $0.stringValue == "" } == true }
        try await type("-6", in: shownFields(window)[0], window, model)
        press("\r", 36, window)
        #expect(["A", "B", "C"].map { gain(studio, $0) } == [-6, -6, -6])
        #expect(undoAll(model, studio) == 1 && studio.session == before, "one entry")
        await model.close()
    }
}
