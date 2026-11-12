import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The index pane on a real session window. The session has tracks Host and Guest, the clips a, b, and c,
/// the marker m1 and the chapter h1 at 48,000, and the marker m2 at 240,000.
@Suite(.serialized) @MainActor struct SessionIndexWindowTests {
    let folder: TemporaryFolder
    let defaults: UserDefaults
    let suite = "SessionIndexWindowTests.\(UUID().uuidString)"
    let app: AppDelegate
    let hal = CountingHAL()

    init() throws {
        folder = try TemporaryFolder()
        defaults = try #require(UserDefaults(suiteName: suite))
        app = AppDelegate(recordings: nil, defaults: defaults)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func package(routed: Bool = false) async throws -> URL {
        let url = folder.url.appending(path: "i-\(UUID().uuidString).dirigible")
        try await Task.detached {
            try Session.create(at: url, sampleRate: 48_000)
            var session = Session(sampleRate: 48_000)
            for (id, path) in [("fa", "Capture/take1-1-1.wav"), ("fb", "Café intro.wav"), ("fc", "take2.wav")] {
                try session.addFile(AudioFile(id: FileID(id), path: path, layout: .mono, length: 480_000))
            }
            try session.addTrack("t1", name: "Host", layout: .mono)
            try session.addTrack("t2", name: "Guest", layout: .mono)
            if routed { try session.setRoute(Route.device(uid: "duo", channels: .mono(1)), track: "t1") }
            try session.place(Clip(id: "a", file: "fa", start: 0, offset: 0, length: 96_000), on: "t1")
            try session.place(Clip(id: "b", file: "fb", start: 48_000, offset: 0, length: 96_000), on: "t2")
            try session.place(Clip(id: "c", file: "fc", start: 192_000, offset: 0, length: 96_000), on: "t1")
            try session.setMarker(Marker(id: "m1", name: "Breath", position: 48_000, kind: .marker))
            try session.setMarker(Marker(id: "h1", name: "Intro", position: 48_000, kind: .chapter))
            try session.setMarker(Marker(id: "m2", name: "Cut here", position: 240_000, kind: .marker))
            try session.write(to: url)
        }.value
        return url
    }

    func open(shown: Bool = true, routed: Bool = false) async throws -> (SessionWindow, Studio, NSWindow) {
        let (model, studio, window, _) = try await openLanes(app, try await package(routed: routed))
        if shown { model.toggleIndex() }
        await until("the window lays out") {
            window.contentView?.layoutSubtreeIfNeeded()
            return model.leadingPane.shown == shown && (!shown || model.leadingPane.table != nil)
        }
        return (model, studio, window)
    }

    func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        let own: [T] = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { views(type, in: $0) }
    }

    func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    func paneSize(_ window: NSWindow, to width: Double) async {
        window.setContentSize(NSSize(width: width, height: 600))
        await until("the window takes \(width) pt") {
            window.contentView?.layoutSubtreeIfNeeded()
            return window.contentLayoutRect.width == width
        }
    }

    @Test func theSwitchHidesWhileThePaneHasOneSegment() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, window) = try await open()
        let controls = views(NSSegmentedControl.self, in: window.contentView)
        let filter = try #require(controls.first { $0.segmentCount == 4 }, "the filter")
        let field = try #require(
            views(NSTextField.self, in: window.contentView).first { $0.isEditable && frame($0).maxX < 260 },
            "the search field")
        let table = try #require(model.leadingPane.table)
        #expect(LeadingPaneState.Segment.allCases.count == 1)
        #expect(!SessionIndexView.showsSwitch(segments: 1) && SessionIndexView.showsSwitch(segments: 2))
        #expect(controls.allSatisfy { $0.segmentCount != 1 }, "a switch with one segment is no control")
        #expect(frame(field).minY > frame(filter).maxY - 1, "the search field is above the filter")
        #expect(frame(filter).minY > frame(table).maxY - 1, "the filter is above the list")
        #expect(frame(table).maxX <= model.leadingPane.width.points, "the pane is the leading column")
        await model.close()
    }

    @Test func twoPanesKeepTheLanesMinimum() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, window) = try await open(shown: false)
        await paneSize(window, to: 1300)
        model.toggleIndex()
        #expect(model.leadingPane.width.points == 240, "a first show opens at 240 pt")
        #expect(model.paneMinimum == 720 + 240, "the minimum counts the index")
        model.leadingPane.width = IndexWidth(260)
        model.toggleInspector()
        model.inspectorWidth = InspectorWidth(270)
        #expect(model.paneMinimum == 720 + 260 + 270, "the minimum counts both panes")

        model.dragInspector(.down(x: 0, clicks: 1))
        model.dragInspector(.drag(x: 300))
        model.dragInspector(.up)
        #expect(model.inspectorWidth.points == 320, "the inspector stops at 1300 - 720 - 260")

        model.inspectorWidth = InspectorWidth(270)
        model.dragIndex(.down(x: 260, clicks: 1))
        model.dragIndex(.drag(x: 560))
        model.dragIndex(.up)
        #expect(model.leadingPane.width.points == 310, "the index stops at 1300 - 720 - 270")
        #expect(defaults.double(forKey: IndexWidth.defaultsKey) == 310, "the up saves the width")
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.contentLayoutRect.width == 1300, "no pane widened the window")

        model.dragIndex(.down(x: 0, clicks: 2))
        #expect(model.leadingPane.width == .standard, "a double-click gives 240 pt")
        await model.close()
    }

    @Test func aShowWidensANarrowWindow() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, window) = try await open(shown: false)
        await paneSize(window, to: 760)
        model.toggleIndex()
        await until("the window takes the index") { window.contentLayoutRect.width >= 960 }
        #expect(window.contentLayoutRect.width >= model.paneMinimum)
        await model.close()
    }

    @Test func theTitleFlipsOnlyAtIndex() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = try await open(shown: false)
        #expect(app.indexItem(for: model).title == .menuViewIndexShow)
        model.run(.toggleIndex)
        #expect(model.leadingPane.shown && app.indexItem(for: model).title == .menuViewIndexHide)
        #expect(defaults.bool(forKey: LeadingPaneState.shownKey), "the shown state is an app preference")
        model.run(.toggleIndex)
        #expect(!model.leadingPane.shown && app.indexItem(for: model).title == .menuViewIndexShow)
        await model.close()
    }

    @Test func aHideGivesTheFocusBackToTheLanes() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, window) = try await open()
        let table = try #require(model.leadingPane.table)
        try #require(window.makeFirstResponder(table))
        model.toggleIndex()
        #expect(window.firstResponder === model.timelineView?.lanes, "Space and Command-Z keep working")
        await model.close()
    }

    @Test func aHiddenPaneBuildsNoRows() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, _) = try await open(shown: false)
        model.addTrack()
        await until("the track is added") { studio.session.tracks.count == 3 }
        #expect(model.leadingPane.builds == 0, "an edit with the pane hidden built rows")
        model.toggleIndex()
        await until("the pane builds its rows") { model.leadingPane.builds == 1 }
        #expect(model.leadingPane.builds == 1, "the shown pane builds once")
        await model.close()
    }

    @Test func theFilterIsGlyphSegmentsWithLabels() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, window) = try await open()
        let filter = try #require(views(NSSegmentedControl.self, in: window.contentView).first { $0.segmentCount == 4 })
        #expect(filter.label(forSegment: 0) == L10n.indexFilterAll.text, "the text All")
        let expected: [(L10n, String)] = [
            (.indexFilterClips, "waveform"), (.menuMarkers, "flag"), (.indexFilterChapters, "bookmark"),
        ]
        for (n, (title, _)) in expected.enumerated() {
            let image = try #require(filter.image(forSegment: n + 1), "segment \(n + 1) shows a glyph")
            #expect(image.accessibilityDescription == title.text, "the label of segment \(n + 1)")
            #expect(filter.toolTip(forSegment: n + 1) == title.text, "the help tag of segment \(n + 1)")
        }
        #expect(filter.toolTip(forSegment: 0) == L10n.indexFilterAll.text)
        await model.close()
    }

    @Test func theFilterBecomesAPullDownWhenNarrow() async throws {
        let filter = IndexKindFilter(kind: .constant(nil))
        for (width, segments, popUps) in [(300.0, 1, 0), (80.0, 0, 1)] {
            let host = NSHostingView(rootView: filter)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 60), styleMask: [.borderless], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            await until("the filter lays out at \(width) pt") {
                host.layoutSubtreeIfNeeded()
                return self.views(NSSegmentedControl.self, in: host).count == segments
                    && self.views(NSPopUpButton.self, in: host).count == popUps
            }
        }
    }

    @Test func theEmptyStatesShowTheirTexts() throws {
        #expect(SessionIndexView.Empty(rows: 3, of: 3) == .none)
        #expect(SessionIndexView.Empty(rows: 0, of: 0) == .session, "an empty session shows its text")
        #expect(SessionIndexView.Empty(rows: 0, of: 6) == .noResults, "a search with no match is not the empty session")
        let english = try stringsTable("en")
        let hint = SessionIndexView.hint { english[$0.rawValue] ?? $0.rawValue }
        #expect(hint == "Press ⌘↩ to add a marker.", "the key of Add Marker")
        #expect(english[L10n.indexEmptySession.rawValue] == "No Clips, Markers, or Chapters")
    }

    @Test func aRowHasAnAccessibilityLabel() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let english = try stringsTable("en")
        let text: (L10n) -> String = { english[$0.rawValue] ?? $0.rawValue }
        let en = Locale(identifier: "en_US")
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "take1.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "a", file: "f", start: Frames(3_600 * 48_000), offset: 0, length: 96_000), on: "t1")
        try session.setMarker(Marker(id: "m1", name: "Breath", position: 48_000, kind: .marker))
        try session.setMarker(Marker(id: "h1", name: "Intro", position: Frames(750 * 48_000), kind: .chapter))
        let rows = SessionIndex(session: session).rows
        let spoken = { (n: Int) in IndexTableSource.spoken(rows[n], rate: 48_000, locale: en, text: text) }
        try #require(rows.count == 3)
        #expect(spoken(0) == "Marker, Breath, 1 second")
        #expect(spoken(1) == "Chapter, Intro, 12 minutes 30 seconds")
        #expect(spoken(2) == "Clip, take1, Host, 1 hour")

        let (model, studio, window) = try await open()
        let table = try #require(model.leadingPane.table)
        await until("the table shows its rows") { table.numberOfRows == 6 }
        window.contentView?.layoutSubtreeIfNeeded()
        let row = try #require(table.rowView(atRow: 1, makeIfNecessary: true), "row h1")
        #expect(
            row.isAccessibilityElement()
                && row.accessibilityLabel()
                    == IndexTableSource.spoken(
                        SessionIndex(session: studio.session).rows[1], rate: 48_000)
        )
        #expect(row.accessibilityChildren()?.isEmpty == true, "a row is one accessibility element")
        await model.close()
    }

    @Test func theListHasNoTypeToSelect() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, window) = try await open()
        let table = try #require(model.leadingPane.table)
        await until("the table shows its rows") { table.numberOfRows == 6 }
        try #require(window.makeFirstResponder(table))
        #expect(!table.allowsTypeSelect, "type-to-select is off")
        // "b" begins the row "Breath": the near input selects it when type-to-select is on.
        window.sendEvent(key(.keyDown, "b", code: 11, in: window))
        #expect(table.selectedRow == -1, "a letter selected a row")
        table.allowsTypeSelect = true
        window.sendEvent(key(.keyDown, "b", code: 11, in: window))
        #expect(table.selectedRow >= 0, "the control: type-to-select selects with the option on")
        await model.close()
    }

    @Test func theTabOrderRunsFromTheToolbarToTheLanes() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, window) = try await open()
        let table = try #require(model.leadingPane.table)
        let lanes = try #require(model.timelineView?.lanes)
        let field = try #require(
            views(NSTextField.self, in: window.contentView).first { $0.isEditable && frame($0).maxX < 260 })
        window.recalculateKeyViewLoop()
        var order: [NSView] = []
        var next = field.nextValidKeyView
        while let view = next, !order.contains(view), order.count < 40 {
            order.append(view)
            next = view.nextValidKeyView
        }
        let position = { (target: NSView) in order.firstIndex { $0 === target || $0.isDescendant(of: target) } }
        let tablePosition = try #require(position(table), "the list is in the loop")
        let lanesPosition = try #require(position(lanes), "the lanes are in the loop")
        #expect(tablePosition < lanesPosition, "the list comes before the lanes")
        if let filter = views(NSSegmentedControl.self, in: window.contentView).first(where: { $0.segmentCount == 4 }),
            let filterPosition = position(filter)
        {
            #expect(filterPosition < tablePosition, "the filter comes before the list")
        }
        await model.close()
    }
}
