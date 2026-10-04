import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The menu item, the width, the states, and the cost of the pane (criteria W1, W2, W3, W7).
extension InspectorTests {
    // MARK: W1

    /// W1: the item shows and hides the pane, keeps the preference, and keeps the focus outside
    /// the pane; a hide with the focus in the pane commits the typed text.
    @Test func theItemTogglesThePaneAndKeepsThePreference() async throws {
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(app.inspectorItem(for: nil) == (title: .menuViewInspectorShow, enabled: false), "no window")
        let (model, studio, window, view) = try await open(try await package(), shown: false)
        #expect(!model.showsInspector)
        #expect(app.inspectorItem(for: model) == (title: .menuViewInspectorShow, enabled: true))

        model.toggleInspector()
        #expect(model.showsInspector && defaults.object(forKey: SessionWindow.inspectorKey) as? Bool == true)
        #expect(app.inspectorItem(for: model) == (title: .menuViewInspectorHide, enabled: true))
        #expect(window.firstResponder === view.lanes, "a show keeps the focus on the lanes")
        model.toggleInspector()
        #expect(!model.showsInspector && defaults.object(forKey: SessionWindow.inspectorKey) as? Bool == false)
        #expect(window.firstResponder === view.lanes, "a hide keeps the focus on the lanes")

        let editor = try await focusName(in: window)
        model.toggleInspector()
        try await Task.sleep(for: .milliseconds(100))
        // A field of a parallel suite can take the shared field editor; the window is then its own
        // first responder (`focusedNameEditor(in:)`). The product never makes that state, and a
        // show that moves the focus gives it to the lanes or the pane.
        #expect(
            window.firstResponder === editor || window.firstResponder === window,
            "a show keeps the focus in the name field: \(String(describing: window.firstResponder))")

        model.timeline.marks = overA
        var fields = try await paneFields(window)
        try await type("-3", in: fields[0], window, model)
        model.toggleInspector()
        #expect(gain(studio, "A") == -3, "a hide commits the typed text")
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.inspectorDraft == nil, "a draft after the hide: \(String(describing: model.inspectorDraft))")
        #expect(window.firstResponder === view.lanes, "a hide gives the focus to the lanes")
        #expect(undoAll(model, studio) == 1, "a hide: one entry")

        model.toggleInspector()
        fields = try await paneFields(window)
        await focus(fields[0], window, model)
        model.toggleInspector()
        #expect(!studio.canUndo && window.firstResponder === view.lanes, "a hide with no typing: no edit")

        model.toggleInspector()
        let (second, _, _, _) = try await open(try await package("b"), shown: false)
        #expect(second.showsInspector, "a new window takes the preference")
        await second.close()
        await model.close()
    }

    // MARK: W2

    /// W2: a show widens a 720 pt window to 990 pt, and the lanes keep their width; a wide
    /// window keeps its width, and the lanes give 270 pt. A hide keeps the window width.
    @Test func showingThePaneWidensANarrowWindow() async throws {
        let (model, _, window, _) = try await open(try await package(), shown: false)
        window.setContentSize(NSSize(width: 500, height: 600))
        await until(limit: .seconds(10), "the window takes its minimum") { window.contentLayoutRect.width == 720 }
        let lanes = layout(window)

        model.toggleInspector()
        #expect(Double(window.contentLayoutRect.width) == 990, "\(window.contentLayoutRect.width)")
        await until("the lanes keep their width") { layout(window) == lanes }
        model.toggleInspector()
        try await Task.sleep(for: .milliseconds(200))
        #expect(Double(window.contentLayoutRect.width) == 990, "a hide keeps the width")

        window.setContentSize(NSSize(width: 1180, height: 600))
        await until("the lanes take 1180 pt") { layout(window) > lanes + 400 }
        let wide = layout(window)
        model.toggleInspector()
        try await Task.sleep(for: .milliseconds(100))
        #expect(Double(window.contentLayoutRect.width) == 1180, "a wide window keeps its width")
        await until("the lanes give 270 pt") { layout(window) == wide - InspectorView.width }
        // The ruler base line must not draw past the lanes into the pane (on-screen check).
        #expect(window.contentView.flatMap(scrollView)?.ruler.clipsToBounds == true, "the ruler clips")
        await model.close()
    }

    /// The width of the lanes scroll view after a layout.
    func layout(_ window: NSWindow) -> Double {
        window.contentView?.layoutSubtreeIfNeeded()
        return Double(window.contentView.flatMap(scrollView)?.frame.width ?? 0)
    }

    func scrollView(in view: NSView) -> TimelineScrollView? {
        view as? TimelineScrollView ?? view.subviews.lazy.compactMap(scrollView).first
    }

    /// W2: at fit zoom (a session shorter than the view), a show and a hide each draw the whole
    /// visible width of the lanes at the new size.
    @Test func theLanesDrawTheNewWidth() async throws {
        let (model, _, window, view) = try await open(try await package(), shown: false)
        for step in ["show", "hide"] {
            let width = view.shown.width
            model.toggleInspector()
            await until("\(step): the lanes take the new width") {
                window.contentView?.layoutSubtreeIfNeeded()
                drawNow(window)
                return view.shown.width != width
                    && view.lanes.drawnRect.contains(view.shown.intersection(view.lanes.bounds))
            }
        }
        await model.close()
    }

    // MARK: W3

    /// W3: the header and the fields in each state. The header is a SwiftUI text with no view, so
    /// its choice is checked through `InspectorView.title`.
    @Test func thePaneShowsEachState() async throws {
        let fades = Fades(fadeIn: 24_000, fadeOut: 0)!
        let url = try await package(
            gains: ["A": -6, "B": -6, "C": -6], fades: ["A": fades, "B": fades, "C": fades], device: "duo")
        let (model, studio, window, _) = try await open(url)
        studio.environment = hal.environment

        #expect(InspectorView.title(nil) == L10n.inspectorClip.text)
        try await Task.sleep(for: .milliseconds(200))
        #expect(shownFields(window).isEmpty, "no selection: no fields")

        model.timeline.marks = overA
        var fields = try await paneFields(window)
        let one = try #require(ClipInspection(marks: overA, session: studio.session))
        #expect(InspectorView.title(one) == "f1")
        #expect(fields.map(\.stringValue) == [decibels(-6), "500", "0"], "\(fields.map(\.stringValue))")

        model.timeline.marks = overAll
        let all = try #require(ClipInspection(marks: overAll, session: studio.session))
        #expect(InspectorView.title(all) == L10n.inspectorClips.format(3))
        fields = try await paneFields(window)
        #expect(fields.map(\.stringValue) == [decibels(-6), "500", "0"], "equal: \(fields.map(\.stringValue))")

        model.edit { s throws(SessionError) in try s.setGain(Gain(dB: 2)!, clip: "B") }
        await until("different gains show Mixed") { shownFields(window).first?.stringValue == "" }
        #expect(shownFields(window).first?.placeholderString == L10n.inspectorMixed.text, "the Mixed placeholder")

        await model.record()
        #expect(studio.transport == .recording(take: 1))
        await until("a take turns the fields off") { shownFields(window).allSatisfy { !$0.isEnabled } }
        #expect(shownFields(window).dropFirst().map(\.stringValue) == ["500", "0"], "a take keeps the values")
        model.toggleInspector()
        model.toggleInspector()
        #expect(model.showsInspector, "the item works during a take")
        await hal.feed(seconds: 0.5)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await until("the take end turns the fields on") { shownFields(window).allSatisfy(\.isEnabled) }
        await model.close()
    }

    // MARK: W7

    /// W7: a hidden pane runs no inspector body; a shown pane runs one per Marks change and adds
    /// no body run of the window content.
    @Test func aHiddenPaneRunsNoBody() async throws {
        let (model, _, window, _) = try await open(try await package(), shown: false)
        try await Task.sleep(for: .milliseconds(200))
        let (runs, bodies) = (model.inspectorRuns, model.bodyRuns)
        for n in 0..<10 { model.timeline.marks = Marks(inPoint: Frames(n * 1_000), outPoint: 200_000, tracks: ["t1"]) }
        model.edit { s throws(SessionError) in try s.setGain(Gain(dB: -1)!, clip: "A") }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.inspectorRuns == runs, "hidden: \(model.inspectorRuns - runs) inspector runs")
        print("InspectorTests: 10 Marks changes and one edit, pane hidden: \(model.bodyRuns - bodies) window bodies")

        let hiddenBodies = model.bodyRuns
        model.timeline.marks = overB
        try await Task.sleep(for: .milliseconds(200))
        // The window content reads the timeline state for the marker rename alert, so a Marks change
        // runs its body once with the pane hidden too. The pane must add no run to that.
        let hiddenChange = model.bodyRuns - hiddenBodies
        print("InspectorTests: one Marks change, pane hidden: \(hiddenChange) window bodies")

        let shownBodies = model.bodyRuns
        model.toggleInspector()
        await until("the pane runs") { model.inspectorRuns > runs }
        try await Task.sleep(for: .milliseconds(200))
        print("InspectorTests: Show Inspector: \(model.bodyRuns - shownBodies) window bodies")
        let loudnessBodies = model.bodyRuns
        model.toggleLoudness()
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        print("InspectorTests: Hide Loudness Meter: \(model.bodyRuns - loudnessBodies) window bodies")

        model.timeline.marks = overB
        _ = try await paneFields(window)
        try await Task.sleep(for: .milliseconds(200))
        let (shownRuns, before) = (model.inspectorRuns, model.bodyRuns)
        model.timeline.marks = overA
        await until("a Marks change runs the pane") { model.inspectorRuns > shownRuns }
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.inspectorRuns == shownRuns + 1, "shown: \(model.inspectorRuns - shownRuns) inspector runs")
        #expect(model.bodyRuns - before == hiddenChange, "shown: \(model.bodyRuns - before) window bodies")
        await model.close()
    }
}
