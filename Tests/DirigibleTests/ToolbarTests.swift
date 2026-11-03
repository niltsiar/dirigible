import AppKit
import DirigibleCore
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The pure values of the session toolbar (decision 0023, ui-shell criteria A2 to A4).
struct ToolbarValueTests {
    /// A2: AppKit saves the customization under these names, so a rename loses the user layout.
    @Test func theToolbarIdentifiersNeverChange() {
        #expect(ToolbarItemID.toolbar == "dirigible.session")
        #expect(
            ToolbarItemID.allCases.map(\.rawValue) == [
                "track.add", "record.monitor", "transport.stop", "transport.play", "transport.record",
                "transport.time", "transport.start", "transport.end", "edit.split", "edit.cut", "edit.copy",
                "edit.paste", "edit.delete", "view.zoom.out", "view.zoom.in", "view.zoom.session", "file.export",
                "view.inspector", "view.snap", "transport.speed", "transport.pre.roll",
            ])
    }

    /// A3: the groups in order, with the spaces between them.
    @Test func theDefaultSetHasTheGroupsInOrder() {
        #expect(
            ToolbarItemID.defaults.map(\.rawValue) == [
                "track.add", "NSToolbarSpaceItem", "record.monitor", "transport.start", "transport.stop",
                "transport.play", "transport.record", "transport.time", "transport.speed", "NSToolbarSpaceItem",
                "edit.split",
                "edit.delete", "NSToolbarFlexibleSpaceItem", "view.zoom.out", "view.zoom.in", "view.zoom.session",
                "view.snap", "file.export", "view.inspector",
            ])
    }

    /// A4: the literal map, and each symbol exists on this system (each is macOS 13 or older).
    @Test func eachItemHasItsSymbol() {
        let symbols: [ToolbarItemID: String] = [
            .addTrack: "waveform.path.badge.plus", .monitor: "mic.and.signal.meter", .stop: "stop.fill",
            .play: "play.fill", .record: "circle.fill", .split: "square.and.line.vertical.and.square",
            .cut: "scissors", .copy: "doc.on.doc", .paste: "doc.on.clipboard", .delete: "trash",
            .zoomOut: "minus.magnifyingglass", .zoomIn: "plus.magnifyingglass",
            .zoomToSession: "arrow.up.left.and.down.right.magnifyingglass", .export: "square.and.arrow.up",
            .start: "backward.end.fill", .end: "forward.end.fill", .inspector: "sidebar.trailing",
            .snap: "arrow.right.and.line.vertical.and.arrow.left", .preRoll: "record.circle",
        ]
        for id in ToolbarItemID.allCases {
            #expect(id.symbol == symbols[id], "\(id)")
            if let symbol = id.symbol {
                #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
            }
        }
    }

    /// A10: the transport and the time stay longest; Input Levels and Export stay before Add
    /// Track and the edit and zoom items.
    @Test func eachItemHasItsPriority() {
        let boost = NSToolbarItem.VisibilityPriority(rawValue: NSToolbarItem.VisibilityPriority.standard.rawValue + 500)
        let priorities: [ToolbarItemID: NSToolbarItem.VisibilityPriority] = [
            .stop: .high, .play: .high, .record: .high, .time: .high, .inspector: .high, .monitor: boost,
            .export: boost,
            .addTrack: .standard, .start: .standard, .end: .standard, .split: .low, .cut: .low, .copy: .low,
            .paste: .low, .delete: .low, .zoomOut: .low, .zoomIn: .low, .zoomToSession: .low, .snap: .low,
            .speed: .low, .preRoll: .low,
        ]
        for id in ToolbarItemID.allCases { #expect(id.priority == priorities[id], "priority of \(id)") }
    }

    @Test func noTwoItemsShareASymbol() {
        let symbols = ToolbarItemID.allCases.compactMap(\.symbol)
        #expect(Set(symbols).count == symbols.count, "\(symbols)")
    }
}

/// The toolbar on a real session window (ui-shell criteria A1, A4, A10, A11).
@Suite(.serialized) @MainActor struct ToolbarWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        folder = try TemporaryFolder()
        // The "prefer tabs" preference of the Mac is a shared resource (the tdd skill).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// A window of an empty package named `name`. The write runs off the main actor.
    func open(_ name: String = "toolbar") async throws -> (SessionWindow, NSWindow, SessionChrome) {
        let url = folder.url.appending(path: "\(name).dirigible")
        try await Task.detached { try Session.create(at: url, sampleRate: 48_000) }.value
        let model = await app.open(url)
        _ = await model.opened()
        return (model, try #require(model.window), try #require(model.chrome))
    }

    /// The identifiers of the items that are in the toolbar, not in the overflow menu (probe P1b).
    func visible(_ chrome: SessionChrome) -> Set<String> {
        Set(chrome.toolbar.visibleItems?.map(\.itemIdentifier.rawValue) ?? [])
    }

    /// Puts the labels of the `language` table on the items. The test process has no app tables in
    /// `Bundle.main`, so its labels are the long keys, which make each item wider than in the app.
    func useLabels(_ language: String, _ chrome: SessionChrome) throws {
        let table = try stringsTable(language)
        for item in chrome.toolbar.items {
            guard let id = ToolbarItemID(rawValue: item.itemIdentifier.rawValue) else { continue }
            item.label = try #require(table[id.label.rawValue])
        }
    }

    /// A1: an AppKit toolbar that a SwiftUI update does not replace (U3, U4, P1a).
    @Test func theWindowHasTheSessionToolbar() async throws {
        let (model, window, chrome) = try await open()
        let host = try #require(window.contentViewController as? NSHostingController<SessionView>)
        let toolbar = try #require(window.toolbar)

        #expect(toolbar === chrome.toolbar)
        #expect(toolbar.identifier == "dirigible.session")
        #expect(toolbar.allowsUserCustomization && toolbar.autosavesConfiguration)
        #expect(window.toolbarStyle == .unified)
        #expect(window.titleVisibility == .visible)
        #expect(host.sceneBridgingOptions == [])

        let studio = try #require(model.studio)
        model.addTrack()
        // The update reached SwiftUI: the lanes of the new track show.
        await until("the window shows the lanes of the new track") { model.timelineView?.window != nil }
        try #require(studio.session.tracks.count == 1)
        try await Task.sleep(for: .seconds(1))

        #expect(window.toolbar === toolbar, "a SwiftUI update replaced the toolbar")
        #expect(window.title == "toolbar")
        await model.close()
    }

    /// V9 (run 2026-10-13-preroll-varispeed): the speed pop-up shows "1×", then the speed in the
    /// accent color, and a pick sets the speed. VoiceOver reads its label and its value. A chrome
    /// turn with no speed change does not change the title.
    @Test func speedPopUpShowsTheSpeed() async throws {
        let (model, _, chrome) = try await open("speed")
        let studio = try #require(model.studio)
        let popUp = try #require(chrome.speedPopUp)
        await until("the pop-up is on after the first chrome turn") { popUp.isEnabled }
        #expect(popUp.titleOfSelectedItem == speedText(.one))
        #expect(popUp.accessibilityLabel() == L10n.menuTransportSpeed.text)
        #expect(popUp.selectedItem?.attributedTitle == nil, "1x has the normal text color")

        await studio.changeSpeed(to: .x150)
        await until("the pop-up shows 1.5") { popUp.titleOfSelectedItem == speedText(.x150) }
        let color = popUp.selectedItem?.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        #expect(color as? NSColor == .controlAccentColor, "another speed has the accent color")
        #expect(popUp.accessibilityValue() as? String == speedSpokenText(.x150))
        let changes = popUp.changes
        for _ in 0..<5 { chrome.update() }
        #expect(popUp.changes == changes, "a turn with no speed change changed the pop-up")

        popUp.selectItem(at: try #require(Speed.allCases.firstIndex(of: .x200)))
        popUp.sendAction(popUp.action, to: popUp.target)
        await until("a pick sets the speed") { studio.speed == .x200 }
        await model.close()
    }

    /// Code gate 1 item 6: a pick that the Studio refuses (a take records) snaps back.
    @Test func aRefusedPickSnapsBack() async throws {
        let (model, _, chrome) = try await open("refused")
        let studio = try #require(model.studio)
        let popUp = try #require(chrome.speedPopUp)
        studio.transport = .recording(take: 1)
        defer { studio.transport = .idle }
        popUp.selectItem(withTag: Speed.x200.rawValue)
        popUp.sendAction(popUp.action, to: popUp.target)
        await until(limit: .seconds(3), "the pop-up shows 1x again") { popUp.titleOfSelectedItem == speedText(.one) }
        #expect(studio.speed == .one)
        await model.close()
    }

    /// Code gate 1 item 7: the overflow submenu checks the speed of the window, and with no speed
    /// unit the pop-up and each speed item are off. The overflow menu shows a copy of the menu
    /// form, made before the change (Phase 7 on screen: the copy kept 1x after a pick of 1.5x).
    @Test func theOverflowCopyFollowsTheWindow() async throws {
        let (model, _, chrome) = try await open("overflow-copy")
        let studio = try #require(model.studio)
        let item = try #require(
            chrome.toolbar.items.first { $0.itemIdentifier.rawValue == ToolbarItemID.speed.rawValue })
        let copy = try #require(item.menuFormRepresentation?.copy() as? NSMenuItem)
        let submenu = try #require(copy.submenu)
        await studio.changeSpeed(to: .x150)
        chrome.update()
        submenu.update()
        let checked = submenu.items.filter { $0.state == .on }.map(\.tag)
        #expect(checked == [Speed.x150.rawValue], "the copy checks another speed")
        studio.environment.speedUnit = { nil }
        chrome.update()
        submenu.update()
        #expect(chrome.speedPopUp?.isEnabled == false)
        #expect(submenu.items.allSatisfy { !$0.isEnabled }, "an overflow speed item is on")
        await model.close()
    }

    /// Icon only by default: 1180 pt fits the default set (ux-decisions 8); the user can pick Icon
    /// and Text in the display-mode menu, and AppKit saves it. The test first removes the saved
    /// configuration of the test process (its own defaults domain, not the app domain): an
    /// earlier run saved Icon and Text there.
    @Test func theDefaultDisplayModeIsIconOnly() async throws {
        UserDefaults.standard.removeObject(forKey: "NSToolbar Configuration \(ToolbarItemID.toolbar)")
        let (model, _, chrome) = try await open()
        #expect(chrome.toolbar.displayMode == .iconOnly)
        await model.close()
    }

    /// A4: the Record symbol is a red color image, not a template, in the toolbar and in the
    /// customization palette. The palette copy draws red in light and dark, and dimmer when
    /// disabled. The toolbar of a window in an inactive app draws every image gray, also a bitmap
    /// (probe P3b), and a test process is never active: the red in the toolbar is manual check M5.
    @Test func theRecordItemIsRed() async throws {
        let (model, _, chrome) = try await open()
        let item = try #require(chrome.toolbar.items.first { $0.itemIdentifier == ToolbarItemID.record.identifier })
        let palette = try #require(
            chrome.toolbar(
                chrome.toolbar, itemForItemIdentifier: ToolbarItemID.record.identifier,
                willBeInsertedIntoToolbar: false))
        let red = NSImage.SymbolConfiguration(paletteColors: [.systemRed])

        for (name, copy) in [("toolbar", item), ("palette", palette)] {
            let button = try #require(copy.view as? NSButton, "\(name)")
            #expect(button.image?.isTemplate == false, "\(name)")
            #expect(button.image?.symbolConfiguration == red, "\(name)")
        }
        let button = try #require(palette.view as? NSButton)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            button.appearance = NSAppearance(named: appearance)
            button.isEnabled = true
            let lit = try redPixels(button)
            button.isEnabled = false
            let dim = try redPixels(button)
            #expect(lit >= 20, "\(appearance.rawValue): \(lit) red pixels")
            #expect(dim < lit / 2, "\(appearance.rawValue): disabled \(dim), enabled \(lit)")
        }
        await model.close()
    }

    /// P33 (run 2026-10-28-pre-roll): the help tag of Record names the key of Record with Pre-roll,
    /// in each table. The test process has no app tables, so the titles and the format come from
    /// each table.
    @Test(arguments: [
        ("en", "Record (⌘R) · Record with Pre-roll (P)"), ("es", "Grabar (⌘R) · Grabar con pre-roll (P)"),
        ("de", "Aufnehmen (⌘R) · Mit Vorlauf aufnehmen (P)"),
        ("fr", "Enregistrer (⌘R) · Enregistrer avec pré-roll (P)"),
        ("it", "Registra (⌘R) · Registra con pre-roll (P)"), ("nl", "Neem op (⌘R) · Neem op met pre-roll (P)"),
        ("pt", "Gravar (⌘R) · Gravar com pré-roll (P)"), ("pt-PT", "Gravar (⌘R) · Gravar com pré-roll (P)"),
    ])
    func recordHelpNamesThePreRollKey(language: String, expected: String) throws {
        let table = try stringsTable(language)
        let text = { (key: L10n) in table[key.rawValue] ?? key.rawValue }

        let tag = toolbarTooltip(.record, format: text(tooltipKey(.record)), text: text)

        #expect(tag == expected, "\(language): \(tag)")
    }

    /// P33: the accessibility hint of the Record item is the help tag, because VoiceOver does not
    /// read a help tag.
    @Test func theRecordHintIsTheHelpTag() async throws {
        let (model, _, chrome) = try await open()
        let item = try #require(chrome.toolbar.items.first { $0.itemIdentifier == ToolbarItemID.record.identifier })
        let button = try #require(item.view as? NSButton)

        #expect(item.toolTip == toolbarTooltip(.record) && item.toolTip?.isEmpty == false)
        #expect(button.accessibilityHelp() == item.toolTip, "the hint differs from the help tag")
        await model.close()
    }

    /// Ruling Q3: Record with Pre-roll is a toolbar item in Customize Toolbar only.
    @Test func thePreRollItemIsInThePaletteOnly() async throws {
        let (model, _, chrome) = try await open()
        let item = try #require(
            chrome.toolbar(
                chrome.toolbar, itemForItemIdentifier: ToolbarItemID.preRoll.identifier,
                willBeInsertedIntoToolbar: false))

        #expect(!ToolbarItemID.defaults.contains(ToolbarItemID.preRoll.identifier))
        #expect(!visible(chrome).contains("transport.pre.roll"))
        #expect(item.toolTip == toolbarTooltip(.recordPreRoll) && item.paletteLabel == L10n.menuRecordPreRoll.text)
        await model.close()
    }

    /// C27 (run ui-polish-chrome): the push-on items have one width, off and on. Today the
    /// symbols give 40 to 51 pt (U5). The copies of the palette give each item, also an item that
    /// the toolbar does not show.
    @Test func theTogglesHaveOneWidth() async throws {
        let (model, _, chrome) = try await open("toggles")
        var widths: [String: Double] = [:]
        for id in ToolbarItemID.allCases.filter(\.isToggle) {
            let item = try #require(
                chrome.toolbar(chrome.toolbar, itemForItemIdentifier: id.identifier, willBeInsertedIntoToolbar: false))
            let button = try #require(item.view as? NSButton, "\(id)")
            for state in [NSControl.StateValue.off, .on] {
                button.state = state
                widths["\(id) \(state == .on ? "on" : "off")"] = Double(button.fittingSize.width)
            }
        }
        let (low, high) = (widths.values.min() ?? 0, widths.values.max() ?? 0)
        #expect(widths.count == 10 && high - low <= 0.5, "\(widths.sorted { $0.key < $1.key })")
        await model.close()
    }

    /// A10: at the minimum width, with a long title, the transport and the time stay in the
    /// toolbar; at 900 pt, Input Levels and Export too (probe P1c). The labels of each language.
    @Test func theTransportStaysVisibleAtTheMinimumWidth() async throws {
        let (model, window, chrome) = try await open(String(repeating: "Interview ", count: 12))
        try #require(window.title.count == 120)
        // C22b: the inspector item stays with the transport.
        let transport: Set<String> = [
            "transport.stop", "transport.play", "transport.record", "transport.time", "view.inspector",
        ]
        let wide = transport.union(["record.monitor", "file.export"])

        for language in AppLanguage.allCases.map(\.rawValue) {
            try useLabels(language, chrome)
            // A smaller size gives the minimum: the content keeps its minimum width.
            window.setContentSize(NSSize(width: 500, height: 600))
            await until(limit: .seconds(10), "\(language): the transport shows at the minimum width") {
                window.layoutIfNeeded()
                return window.contentLayoutRect.width == 720 && visible(chrome).isSuperset(of: transport)
            }
            #expect(window.contentLayoutRect.width == 720, "\(language)")
            #expect(visible(chrome).isSuperset(of: transport), "\(language): \(visible(chrome).sorted())")

            window.setContentSize(NSSize(width: 900, height: 600))
            await until(limit: .seconds(10), "\(language): Input Levels and Export show at 900 pt") {
                window.layoutIfNeeded()
                return visible(chrome).isSuperset(of: wide)
            }
            #expect(visible(chrome).isSuperset(of: wide), "\(language): \(visible(chrome).sorted())")
        }
        await model.close()
    }

    /// A11: min(1180 pt, the screen) x 720 pt, and a second window cascades from the first. At
    /// 1180 pt every default item shows with the labels of each language.
    @Test func aNewWindowShowsTheDefaultToolbar() async throws {
        let (first, window, chrome) = try await open("first")
        let screen = try #require(window.screen).visibleFrame.width
        let width = min(1180, screen)

        #expect(window.contentLayoutRect.size == NSSize(width: width, height: 720), "screen width \(screen)")
        if width == 1180 {
            let items = Set(ToolbarItemID.defaults.map(\.rawValue))
            for language in AppLanguage.allCases.map(\.rawValue) {
                try useLabels(language, chrome)
                await until(limit: .seconds(10), "\(language): every default item shows at 1180 pt") {
                    window.layoutIfNeeded()
                    return visible(chrome) == items
                }
                #expect(visible(chrome) == items, "\(language): \(items.subtracting(visible(chrome)).sorted())")
            }
        }
        let (second, next, _) = try await open("second")
        #expect(next.frame.minX > window.frame.minX, "\(next.frame) after \(window.frame)")
        #expect(next.frame.maxY < window.frame.maxY, "\(next.frame) after \(window.frame)")
        await second.close()
        await first.close()
    }
}

/// The pixels of a draw of `view` that are red: R over 180, G and B under 90 (0 to 255), and
/// alpha over 0.7, so a dimmed red that is partly transparent does not count.
@MainActor func redPixels(_ view: NSView) throws -> Int {
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    var count = 0
    for x in 0..<bitmap.pixelsWide {
        for y in 0..<bitmap.pixelsHigh {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.alphaComponent > 0.7, color.redComponent > 180 / 255, color.greenComponent < 90 / 255,
                color.blueComponent < 90 / 255
            {
                count += 1
            }
        }
    }
    return count
}
