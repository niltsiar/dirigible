import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The menu side of the toolbar (ui-shell criteria A5, A6, A8): each item is a menu item with a
/// key, and the palette label, the key in the tooltip, and the action come from that item.
struct ToolbarMenuTests {
    /// The key of each toolbar item as its tooltip shows it.
    static let keys: [ToolbarItemID: String] = [
        .addTrack: "⌥⌘N", .monitor: "⇧⌘M", .stop: "⌘.", .play: "key.space", .record: "⌘R", .start: "↖",
        .end: "↘", .split: "⌘B", .cut: "⌘X", .copy: "⌘C", .paste: "⌘V", .delete: "⌫", .zoomOut: "⌘-",
        .zoomIn: "⌘+", .zoomToSession: "⌘0", .export: "⌘E", .inspector: "⌥⌘I",
    ]

    /// A5: each item but the time display has a command, and the menu tables give that command a
    /// title and a key.
    @Test func eachToolbarItemIsAMenuItemWithAKey() {
        for id in ToolbarItemID.allCases where id != .time {
            guard let command = id.command else {
                Issue.record("\(id) has no command")
                continue
            }
            #expect(keyText(command.menuItem.key) == Self.keys[id], "key of \(id)")
        }
        #expect(ToolbarItemID.time.command == nil)
        #expect(WindowCommand.transport(.playStop).menuItem.title == .menuTransportPlay)
        #expect(WindowCommand.transport(.seek(.end)).menuItem.title == .menuTransportEnd)
        #expect(WindowCommand.stop.menuItem.title == .menuTransportStop)
    }

    /// A6: Input Levels has Shift-Command-M, Show/Hide Toolbar has Option-Command-T, and no key
    /// is on two items.
    @Test func theNewKeysAreFree() {
        #expect(MenuKeys.monitor == KeyboardShortcut("m", modifiers: [.command, .shift]))
        #expect(MenuKeys.system.contains(KeyboardShortcut("t", modifiers: [.command, .option])))
        // The system Settings… item (C5), so no app item takes Command-comma.
        #expect(MenuKeys.system.contains(KeyboardShortcut(",")))
        #expect(MenuKeys.all.contains(MenuKeys.monitor))
        let items = TransportMenu.groups.flatMap { $0 }
        #expect(
            items.map(\.command) == [
                .playStop, .stopAndReturn, .reverse, .pause, .forward, .slowReverse, .slowForward, .seek(.start),
                .seek(.end), .seek(.previousClip), .seek(.nextClip),
            ])
        for item in items { #expect(MenuKeys.all.contains(item.key), "\(item.command)") }
    }
}

/// The toolbar items on a real session window (ui-shell criteria A5, A7, A8).
@Suite(.serialized) @MainActor struct ToolbarCommandTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()

    init() throws {
        folder = try TemporaryFolder()
        NSWindow.allowsAutomaticWindowTabbing = false
        app.chooseExport = { _, _, _, _, _, done in done(nil) }
    }

    /// A window of 2 tracks on channel 1 of `duo`, each with a 10 s clip, the counting HAL, and
    /// the offline Player, as the key window of `app`.
    func open() async throws -> (SessionWindow, Studio, NSWindow, SessionChrome) {
        let url = try await timelinePackage(in: folder.url, tracks: 2, seconds: 10, audio: true, device: "duo")
        let (model, studio, window, _) = try await openLanes(app, url)
        studio.environment = hal.environment
        studio.environment.playerOutput = .offline
        let chrome = try #require(model.chrome)
        await until("the toolbar has its items") { chrome.time != nil }
        return (model, studio, window, chrome)
    }

    /// The item of `id`: the toolbar copy, or a palette copy for a palette-only item.
    func item(_ id: ToolbarItemID, _ chrome: SessionChrome) throws -> NSToolbarItem {
        if let item = chrome.toolbar.items.first(where: { $0.itemIdentifier == id.identifier }) { return item }
        return try #require(
            chrome.toolbar(chrome.toolbar, itemForItemIdentifier: id.identifier, willBeInsertedIntoToolbar: false))
    }

    /// A click on the item: the button of a push-on item, else the item action. A disabled button
    /// takes no click, and the loop turn that enables it can come late in a full run: wait for it.
    func click(_ id: ToolbarItemID, _ chrome: SessionChrome) async throws {
        let item = try item(id, chrome)
        guard let button = item.view as? NSButton else { return chrome.runItem(item) }
        await until(limit: .seconds(10), "\(id) is enabled") { button.isEnabled }
        button.performClick(nil)
    }

    /// A5: for each item but the time display and the pasteboard items, a toolbar click and its
    /// menu path reach the same leaf of the window with the same argument.
    @Test func theToolbarAndTheMenuReachTheSameLeaf() async throws {
        let (model, studio, window, chrome) = try await open()
        studio.environment.microphoneAccess = { .denied }
        let pasteboard: Set<ToolbarItemID> = [.time, .cut, .copy, .paste, .delete]
        for id in ToolbarItemID.allCases where !pasteboard.contains(id) {
            let command = try #require(id.command)
            model.leafCalls = []
            try await click(id, chrome)
            let toolbar = model.leafCalls ?? []
            model.leafCalls = []
            switch command {
            case .timeline(let command): app.timeline(command, event: nil, in: window)
            case .transport(let command): app.transport(command, event: nil, in: window)
            case .addTrack, .record, .stop, .toggleMonitor, .toggleInspector: app.key?.run(command)
            }
            let menu = model.leafCalls ?? []
            #expect(!toolbar.isEmpty, "the \(id) click reached no leaf")
            #expect(toolbar == menu, "\(id): toolbar \(toolbar), menu \(menu)")
        }
        model.leafCalls = nil
        await studio.perform(.pause)
        await model.close()
    }

    /// A5: Add Track adds a track, Zoom In halves the frames per point, Input Levels sets the
    /// toggle, and Cut from the palette removes the selected range, or the selected text of a
    /// focused name field (the responder chain, 0018 E3).
    @Test func aToolbarClickRunsItsMenuCommand() async throws {
        let (model, studio, window, chrome) = try await open()
        try await click(.addTrack, chrome)
        #expect(studio.session.tracks.count == 3)

        let view = try #require(model.timelineView)
        let zoom = view.framesPerPoint
        try await click(.zoomIn, chrome)
        #expect(abs(view.framesPerPoint - zoom / 2) < 0.001, "\(view.framesPerPoint) after \(zoom)")

        try await click(.monitor, chrome)
        #expect(model.monitoring)
        try await click(.monitor, chrome)
        #expect(!model.monitoring)

        model.timeline.marks = Marks(inPoint: 0, outPoint: 24_000, tracks: ["t1"])
        try await click(.cut, chrome)
        // Cut closes the gap (decision 0037): the clip starts at 0 and is 24 000 frames shorter.
        let first = studio.session.track("t1")?.clips.first
        #expect(first?.start == 0 && first?.length == 456_000, "Cut removed no range: \(String(describing: first))")

        let editor = try await focusName(in: window)
        editor.selectAll(nil)
        let session = studio.session
        try await click(.cut, chrome)
        #expect(editor.string == "", "Cut left the text \(editor.string)")
        #expect(studio.session == session, "Cut changed the session with a focused field")
        await model.close()
    }

    /// Criterion Z4, the closest automated check (a test has no real microphone): during a take, a
    /// click on Zoom In halves the frames per point. Control: Zoom In off during the take fails the
    /// state read.
    @Test func aZoomClickDuringATakeZooms() async throws {
        let (model, studio, _, chrome) = try await open()
        model.armed = ["t1"]
        await model.record()
        try #require(model.canStop)
        await hal.feed(seconds: 0.2)
        let record = try #require(try item(.record, chrome).view as? NSButton)
        await until(limit: .seconds(10), "the toolbar shows the take") { record.state == .on }
        let view = try #require(model.timelineView)
        let zoom = view.framesPerPoint
        // `click` runs an item with no button view directly, so the test reads the state first.
        #expect(try item(.zoomIn, chrome).isEnabled, "Zoom In is off during the take")

        try await click(.zoomIn, chrome)

        #expect(abs(view.framesPerPoint - zoom / 2) < 0.001, "\(view.framesPerPoint) after \(zoom)")
        model.run(.stop)
        await until("the take ends") { studio.transport == .idle }
        await model.close()
    }

    /// A7: Stop ends a take, and the take stays in the session.
    @Test func stopEndsATakeAndKeepsIt() async throws {
        let (model, studio, _, _) = try await open()
        // Both tracks use channel 1 of duo: one take track.
        model.armed = ["t1"]
        await model.record()
        try #require(model.canStop)
        await hal.feed(seconds: 0.2)
        #expect(model.shown.isRunning)

        model.run(.stop)

        await until("the take ends") { studio.transport == .idle }
        #expect(studio.session.tracks.flatMap(\.clips).contains { $0.id.rawValue.hasPrefix("take1") }, "no take clip")
        #expect(studio.pendingTake == nil)
        await until(limit: .seconds(5), "Stop goes off") { !model.shown.isRunning }
        #expect(!model.shown.isRunning)
        await model.close()
    }

    /// A7: with no take, Stop ends the play and keeps the playhead where it stopped.
    @Test func stopEndsAPlayAndKeepsThePlayhead() async throws {
        let (model, studio, _, _) = try await open()
        await studio.perform(.seek(.frame(48_000)))
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 9_600)
        await until(limit: .seconds(10), "the play moves") { studio.playhead > 48_000 }
        await until(limit: .seconds(5), "Stop is on during the play") { model.shown.isRunning }
        #expect(model.shown.isRunning)

        model.run(.stop)

        await until("the play stops") { studio.playback == .stopped }
        #expect(studio.playhead > 48_000, "Stop went back to \(studio.playhead)")
        await until(limit: .seconds(5), "Stop goes off") { !model.shown.isRunning }
        #expect(!model.shown.isRunning)
        await model.close()
    }

    /// A8: customization, the palette-only items, the labels (12 characters or fewer in both
    /// tables), the palette labels from the menu tables, the tooltips with the key, and the
    /// possible labels of the current locale.
    @Test func theToolbarCanBeCustomized() async throws {
        let (model, _, _, chrome) = try await open()
        let toolbar = chrome.toolbar
        #expect(toolbar.allowsUserCustomization && toolbar.autosavesConfiguration)
        let allowed = Set(chrome.toolbarAllowedItemIdentifiers(toolbar).map(\.rawValue))
        let defaults = Set(chrome.toolbarDefaultItemIdentifiers(toolbar).map(\.rawValue))
        #expect(
            allowed
                == Set(ToolbarItemID.allCases.map(\.rawValue) + ["NSToolbarSpaceItem", "NSToolbarFlexibleSpaceItem"]))
        #expect(
            allowed.subtracting(defaults) == [
                "edit.cut", "edit.copy", "edit.paste", "transport.end",
            ])

        let tables = (en: try stringsTable("en"), es: try stringsTable("es"))
        for id in ToolbarItemID.allCases {
            let item = try item(id, chrome)
            for table in [tables.en, tables.es] {
                let label = try #require(table[id.label.rawValue])
                #expect(label.count <= 12, "label of \(id): \(label)")
            }
            #expect(item.label == id.label.text)
            #expect(item.possibleLabels == [id.label.text])
            guard let command = id.command else { continue }
            #expect(item.paletteLabel == command.menuItem.title.text, "palette label of \(id)")
            let key = try #require(Self.keys(id))
            #expect(item.toolTip == toolbarTooltip(command), "tooltip of \(id)")
            // The test process has no app tables, so the format comes from each table.
            for table in [tables.en, tables.es] {
                let format = try #require(table[L10n.toolbarTooltip.rawValue])
                #expect(
                    toolbarTooltip(command, format: format) == "\(command.menuItem.title.text) (\(key))",
                    "tooltip of \(id)")
            }
        }
        await model.close()
    }

    static func keys(_ id: ToolbarItemID) -> String? {
        ToolbarMenuTests.keys[id].map { $0 == "key.space" ? L10n.keySpace.text : $0 }
    }

    /// C21: the inspector item toggles the pane as View > Show Inspector does, and it is on while
    /// the pane shows.
    @Test func theInspectorItemTogglesThePane() async throws {
        let (model, _, _, chrome) = try await open()
        let button = try #require(try item(.inspector, chrome).view as? NSButton)
        for shows in [true, false] {
            try await click(.inspector, chrome)
            #expect(model.showsInspector == shows)
            await until(limit: .seconds(10), "the item is on while the pane shows: \(shows)") {
                (button.state == .on) == shows
            }
        }
        await model.close()
    }
}
