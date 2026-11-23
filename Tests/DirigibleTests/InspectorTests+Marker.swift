import AppKit
import DirigibleCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleTimeline

/// The Marker pane (run 2026-10-11-chapters-in-file, criterion C9) in the window of
/// `InspectorTests`: the chapter c1 "One" at 1 s, the marker m2 "Two" at 2 s, and the chapter c3
/// "Three" at 3 s.
extension InspectorTests {
    func addMarkers(_ model: SessionWindow) {
        model.edit(ripple: false) { s throws(SessionError) in
            try s.setMarker(Marker(id: "c1", name: "One", position: 48_000, kind: .chapter))
            try s.setMarker(Marker(id: "m2", name: "Two", position: 96_000, kind: .marker))
            try s.setMarker(Marker(id: "c3", name: "Three", position: 144_000, kind: .chapter))
        }
    }

    /// The editable fields of the Marker pane, top first: Name, Link.
    func markerFields(_ window: NSWindow) async throws -> [NSTextField] {
        await until(limit: .seconds(10), "the Marker pane shows its fields") { shownFields(window).count == 2 }
        let fields = shownFields(window)
        try #require(fields.count == 2, "Name and Link")
        return fields
    }

    /// Waits until Name has the focus with its whole text selected.
    func waitForNameFocus(_ model: SessionWindow, _ window: NSWindow, _ name: String) async throws {
        let field = try await markerFields(window)[0]
        await until(limit: .seconds(10), "the focus goes to Name") {
            model.markerFocus == .name && (focusedField(window) === field || window.firstResponder === window)
        }
        #expect(
            model.markerFocus == .name,
            "focus \(String(describing: model.markerFocus)), responder \(String(describing: window.firstResponder))")
        if let editor = window.firstResponder as? NSTextView, focusedField(window) === field {
            #expect(editor.selectedRange() == NSRange(location: 0, length: name.utf16.count), "Name is selected")
        }
    }

    /// Item 1398: Markers > Marker Info from Link puts the focus in Name also when the first focus
    /// move ends at once and the pane never sees Name.
    @Test func markerInfoKeepsItsFocusRequestUntilNameHasTheFocus() async throws {
        let (model, _, window, _) = try await open(try await package())
        addMarkers(model)
        model.timeline.marker = "c1"
        model.run(.markerInfo)
        try await waitForNameFocus(model, window, "One")
        let link = try await markerFields(window)[1]
        await until("Link has the focus") {
            if focusedField(window) !== link { window.makeFirstResponder(link) }
            return model.markerFocus == .url
        }

        let (observation, ended) = endNextFieldEdit(in: window)
        model.run(.markerInfo)
        await until(limit: .seconds(10), "the first focus move ends") { ended() }
        let name = try await markerFields(window)[0]
        await until(limit: .seconds(10), "Name edits with the focus") {
            model.markerFocus == .name && focusedField(window) === name
        }
        observation.invalidate()
        await model.close()
    }

    /// A square PNG of `side` x `height` px in the test folder.
    func png(_ name: String, side: Int = 64, height: Int? = nil) throws -> URL {
        let url = folder.url.appending(path: name)
        let context = try #require(
            CGContext(
                data: nil, width: side, height: height ?? side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    /// C9: Markers > Marker Info… shows the Marker pane with the focus in Name, from the pane
    /// hidden, the Clip tab with the focus in a clip field, the Episode tab with the focus in
    /// Title, the Marker tab with the focus in Link, and the lanes. With no current marker it beeps
    /// and the pane shows "No Marker".
    @Test func markerInfoShowsTheMarkerPaneWithTheFocusInName() async throws {
        let (model, studio, window, view) = try await open(try await package(), shown: false)
        var beeps = 0
        model.beep = { beeps += 1 }
        addMarkers(model)
        let edits = studio.session

        model.run(.markerInfo)
        #expect(beeps == 1 && model.showsInspector && model.inspectorTab == .marker, "no marker: \(beeps) beeps")
        try await Task.sleep(for: .milliseconds(200))
        #expect(shownFields(window).isEmpty, "No Marker: no fields")

        model.toggleInspector()
        model.timeline.marker = "c1"
        model.run(.markerInfo)
        #expect(model.showsInspector && model.inspectorTab == .marker, "from a hidden pane")
        try await waitForNameFocus(model, window, "One")
        #expect(try await markerFields(window).map(\.stringValue) == ["One", ""])

        model.inspectorTab = .clip
        model.timeline.marks = overA
        await focus(try await paneFields(window)[0], window, model)
        model.run(.markerInfo)
        #expect(model.inspectorTab == .marker, "from the Clip tab")
        try await waitForNameFocus(model, window, "One")

        model.showEpisodeInfo()
        try await waitForTitleFocus(model, window)
        model.run(.markerInfo)
        #expect(model.inspectorTab == .marker, "from the Episode tab")
        try await waitForNameFocus(model, window, "One")

        let link = try await markerFields(window)[1]
        await until("Link has the focus") {
            if focusedField(window) !== link { window.makeFirstResponder(link) }
            return model.markerFocus == .url
        }
        model.run(.markerInfo)
        try await waitForNameFocus(model, window, "One")

        #expect(window.makeFirstResponder(view.lanes))
        model.run(.markerInfo)
        try await waitForNameFocus(model, window, "One")
        #expect(beeps == 1 && studio.session == edits, "no edit, one beep")
        await model.close()
    }

    /// C9: a double-click on a flag shows the Marker pane of that flag; a flag drag after the
    /// double-click still moves the flag. One click keeps the tab, and the pane follows the
    /// current marker.
    @Test func aDoubleClickOnAFlagShowsTheMarkerPane() async throws {
        let (model, studio, window, view) = try await open(try await package())
        addMarkers(model)
        await until("the ruler shows the flags") { view.ruler.inputs?.markers.count == 3 }
        let x = try #require(view.ruler.inputs?.geometry.x(of: 96_000)) + 1
        let mouse = { (type: NSEvent.EventType, x: Double, clicks: Int) in
            try rulerMouse(type, x, 10, in: view, clicks: clicks)
        }

        view.ruler.mouseDown(with: try mouse(.leftMouseDown, x, 1))
        view.ruler.mouseUp(with: try mouse(.leftMouseUp, x, 1))
        #expect(model.timeline.marker == "m2" && model.inspectorTab == .clip, "one click keeps the tab")

        view.ruler.mouseDown(with: try mouse(.leftMouseDown, x, 2))
        #expect(model.inspectorTab == .marker && model.timeline.marker == "m2", "the double-click")
        try await waitForNameFocus(model, window, "Two")
        view.ruler.mouseDragged(with: try mouse(.leftMouseDragged, x + 40, 2))
        view.ruler.mouseUp(with: try mouse(.leftMouseUp, x + 40, 2))
        #expect(studio.session.markers["m2"]?.position != 96_000, "the drag moved the flag")
        model.undo()
        #expect(studio.session.markers["m2"]?.position == 96_000, "the move is one undo entry")

        model.timeline.marker = "c3"
        await until(limit: .seconds(5), "the pane follows the current marker") {
            shownFields(window).first?.stringValue == "Three"
        }
        #expect(shownFields(window).map(\.stringValue) == ["Three", ""], "\(shownFields(window).map(\.stringValue))")
        await model.close()
    }

    /// C9: a Name commit and a Link commit are one undo entry each; an empty Link clears the link;
    /// Esc puts back the text.
    @Test func aNameAndALinkCommitAreOneUndoEntryEach() async throws {
        let (model, studio, window, view) = try await open(try await package())
        addMarkers(model)
        _ = undoAll(model, studio)
        addMarkers(model)
        model.timeline.marker = "c1"
        model.run(.markerInfo)
        try await waitForNameFocus(model, window, "One")

        model.typeMarker("Intro", in: .name, of: "c1")
        model.commitMarker()
        model.typeMarker("https://example.com/one", in: .url, of: "c1")
        model.commitMarker()
        let c1 = try #require(studio.session.markers["c1"])
        #expect(c1.name == "Intro" && c1.url?.text == "https://example.com/one" && c1.kind == .chapter)
        #expect(undoAll(model, studio) == 3, "the markers, the name, and the link")

        addMarkers(model)
        try await waitForNameFocus(model, window, "One")
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("Typed", replacementRange: editor.selectedRange())
        #expect(model.markerDraft?.text == "Typed")
        press("\u{1b}", 53, window)
        await until("Esc gives the focus to the lanes") { window.firstResponder === view.lanes }
        #expect(model.markerDraft == nil && studio.session.markers["c1"]?.name == "One", "Esc made no edit")
        #expect(try await markerFields(window)[0].stringValue == "One", "Name shows its old text")
        await model.close()
    }

    /// C9, G2: a bad link, also a link of 256 bytes, beeps once, keeps the session value and the
    /// focus, and shows the rule. A link of 255 bytes saves. A name with a tab is refused too.
    @Test func aBadLinkBeepsOnceAndKeepsTheFocus() async throws {
        let (model, studio, window, _) = try await open(try await package())
        var beeps = 0
        model.beep = { beeps += 1 }
        addMarkers(model)
        model.timeline.marker = "c1"
        model.run(.markerInfo)
        try await waitForNameFocus(model, window, "One")
        let before = studio.session
        let long = "https://example.com/" + String(repeating: "a", count: Marker.maximumURLBytes - 20)
        #expect(long.utf8.count == 255)

        for (field, text) in [(MarkerField.url, "ftp://a.b"), (.url, long + "a"), (.name, "A\tB")] {
            model.typeMarker(text, in: field, of: "c1")
            model.commitMarker()
            model.commitMarker()
            #expect(
                model.markerDraft
                    == MarkerDraft(
                        marker: "c1", field: field, shown: field == .name ? "One" : "", text: text, refused: true))
            model.markerDraft = nil
        }
        #expect(beeps == 3 && studio.session == before && model.alert == nil, "beeps: \(beeps)")
        #expect(MarkerInspector.refusal(.url) == .errorMarkerURL && MarkerInspector.refusal(.name) == .errorEpisodeLine)

        let link = try await markerFields(window)[1]
        await until("Link has the focus") {
            if focusedField(window) !== link { window.makeFirstResponder(link) }
            return model.markerFocus == .url && focusedField(window) === link
        }
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("ftp://a.b", replacementRange: editor.selectedRange())
        press("\r", 36, window)
        #expect(beeps == 4 && model.markerDraft?.refused == true)
        #expect(focusedField(window) === link || window.firstResponder === window, "the focus stays in Link")
        model.typeMarker(long, in: .url, of: "c1")
        model.commitMarker()
        #expect(studio.session.markers["c1"]?.url?.text == long && model.markerDraft == nil, "255 bytes save")
        await model.close()
    }

    /// C9: Choose… or a drop sets the chapter image as one entry; Remove clears it as one entry
    /// and keeps the file; a refused image shows the artwork alert.
    @Test func aChapterImageSetAndRemoveAreOneUndoEntryEach() async throws {
        let (model, studio, _, _) = try await open(try await package())
        addMarkers(model)
        model.timeline.marker = "c3"
        model.run(.markerInfo)

        model.setMarkerImage(try png("chapter.png"))
        await model.importJob?.task?.value
        let name = try #require(studio.session.markers["c3"]?.image)
        model.removeMarkerImage()
        #expect(studio.session.markers["c3"]?.image == nil)
        #expect(FileManager.default.fileExists(atPath: studio.url.appending(path: name.path).path), "the file stays")
        #expect(undoAll(model, studio) == 3, "the markers and one entry each")

        addMarkers(model)
        model.setMarkerImage(try png("wide.png", side: 64, height: 32))
        await model.importJob?.task?.value
        #expect(model.alert != nil && studio.session.markers["c3"]?.image == nil, "the artwork alert")
        await model.close()
    }

    /// C9: a plain marker shows Link disabled; it takes no link and no image.
    @Test func aPlainMarkerTakesNoLinkAndNoImage() async throws {
        let (model, studio, window, _) = try await open(try await package())
        var beeps = 0
        model.beep = { beeps += 1 }
        addMarkers(model)
        model.timeline.marker = "m2"
        model.run(.markerInfo)
        let fields = try await markerFields(window)
        #expect(fields[0].isEnabled && !fields[1].isEnabled, "Name on, Link off")
        let before = studio.session

        model.typeMarker("https://example.com", in: .url, of: "m2")
        #expect(model.markerDraft == nil)
        model.setMarkerImage(try png("plain.png"))
        #expect(beeps == 1 && model.importJob == nil && studio.session == before)
        await model.close()
    }

    /// C9: a draft typed for marker A commits to A when a flag click, Next Marker, or Add Chapter
    /// makes marker B current, and also when a later commit runs after the change.
    @Test func aDraftCommitsToItsMarkerWhenTheCurrentMarkerChanges() async throws {
        let (model, studio, window, view) = try await open(try await package())
        addMarkers(model)
        await until("the ruler shows the flags") { view.ruler.inputs?.markers.count == 3 }
        model.timeline.marker = "c1"
        model.run(.markerInfo)
        try await waitForNameFocus(model, window, "One")

        model.typeMarker("Alpha", in: .name, of: "c1")
        model.timeline.marker = "c3"
        model.commitMarker()
        #expect(studio.session.markers["c1"]?.name == "Alpha" && studio.session.markers["c3"]?.name == "Three")

        model.typeMarker("Gamma", in: .name, of: "c3")
        let x = try #require(view.ruler.inputs?.geometry.x(of: 96_000)) + 1
        view.ruler.mouseDown(with: try rulerMouse(.leftMouseDown, x, 10, in: view))
        view.ruler.mouseUp(with: try rulerMouse(.leftMouseUp, x, 10, in: view))
        #expect(model.timeline.marker == "m2" && studio.session.markers["c3"]?.name == "Gamma", "a flag click")
        #expect(studio.session.markers["m2"]?.name == "Two")

        model.typeMarker("Beta", in: .name, of: "m2")
        await studio.perform(.seek(.frame(100_000)))
        model.run(.nextMarker)
        #expect(model.timeline.marker == "c3" && studio.session.markers["m2"]?.name == "Beta", "Next Marker")

        model.typeMarker("Last", in: .name, of: "c3")
        model.run(.addChapter)
        #expect(model.timeline.marker != "c3" && studio.session.markers["c3"]?.name == "Last", "Add Chapter")
        await model.close()
    }

    /// C9: during a take the fields are read-only.
    @Test func theMarkerPaneIsReadOnlyDuringATake() async throws {
        let (model, studio, window, _) = try await open(try await package(device: "duo"))
        studio.environment = hal.environment
        addMarkers(model)
        model.timeline.marker = "c1"
        model.run(.markerInfo)
        _ = try await markerFields(window)

        await model.record()
        #expect(studio.transport == .recording(take: 1))
        await until("a take turns the fields off") { shownFields(window).allSatisfy { !$0.isEnabled } }
        model.typeMarker("Typed", in: .name, of: "c1")
        #expect(model.markerDraft == nil, "no draft during a take")
        await hal.feed(seconds: 0.5)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await until("the take end turns Name on") { shownFields(window).first?.isEnabled == true }
        await model.close()
    }
}
