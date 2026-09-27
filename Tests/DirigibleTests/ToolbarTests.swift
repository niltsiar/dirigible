import AppKit
import DirigibleCore
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp

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
            ])
    }

    /// A3: the groups in order, with the spaces between them.
    @Test func theDefaultSetHasTheGroupsInOrder() {
        #expect(
            ToolbarItemID.defaults.map(\.rawValue) == [
                "track.add", "NSToolbarSpaceItem", "record.monitor", "transport.stop", "transport.play",
                "transport.record", "transport.time", "NSToolbarSpaceItem", "edit.split", "edit.delete",
                "NSToolbarFlexibleSpaceItem", "view.zoom.out", "view.zoom.in", "view.zoom.session", "file.export",
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
            .start: "backward.end.fill", .end: "forward.end.fill",
        ]
        for id in ToolbarItemID.allCases {
            #expect(id.symbol == symbols[id], "\(id)")
            if let symbol = id.symbol {
                #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
            }
        }
    }

    /// A10: the transport and the time stay longest; Monitor Inputs and Export stay before Add
    /// Track and the edit and zoom items.
    @Test func eachItemHasItsPriority() {
        let boost = NSToolbarItem.VisibilityPriority(rawValue: NSToolbarItem.VisibilityPriority.standard.rawValue + 500)
        let priorities: [ToolbarItemID: NSToolbarItem.VisibilityPriority] = [
            .stop: .high, .play: .high, .record: .high, .time: .high, .monitor: boost, .export: boost,
            .addTrack: .standard, .start: .standard, .end: .standard, .split: .low, .cut: .low, .copy: .low,
            .paste: .low, .delete: .low, .zoomOut: .low, .zoomIn: .low, .zoomToSession: .low,
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

    /// A10: at the minimum width, with a long title, the transport and the time stay in the
    /// toolbar; at 900 pt, Monitor Inputs and Export too (probe P1c). English and Spanish labels.
    @Test func theTransportStaysVisibleAtTheMinimumWidth() async throws {
        let (model, window, chrome) = try await open(String(repeating: "Interview ", count: 12))
        try #require(window.title.count == 120)
        let transport: Set<String> = ["transport.stop", "transport.play", "transport.record", "transport.time"]
        let wide = transport.union(["record.monitor", "file.export"])

        for language in ["en", "es"] {
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
            await until(limit: .seconds(10), "\(language): Monitor Inputs and Export show at 900 pt") {
                window.layoutIfNeeded()
                return visible(chrome).isSuperset(of: wide)
            }
            #expect(visible(chrome).isSuperset(of: wide), "\(language): \(visible(chrome).sorted())")
        }
        await model.close()
    }

    /// A11: min(1180 pt, the screen) x 720 pt, and a second window cascades from the first. At
    /// 1180 pt every default item shows with the English labels and with the Spanish labels.
    @Test func aNewWindowShowsTheDefaultToolbar() async throws {
        let (first, window, chrome) = try await open("first")
        let screen = try #require(window.screen).visibleFrame.width
        let width = min(1180, screen)

        #expect(window.contentLayoutRect.size == NSSize(width: width, height: 720), "screen width \(screen)")
        if width == 1180 {
            let items = Set(ToolbarItemID.defaults.map(\.rawValue))
            for language in ["en", "es"] {
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
