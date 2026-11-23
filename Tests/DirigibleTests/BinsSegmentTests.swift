import AVFoundation
import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The Bins segment of the leading pane (F22). The session has tracks Host and Guest, the clips a (Host,
/// 0 to 96,000), b (Guest, 48,000 to 144,000), and c (Host, 192,000 to 288,000) of three WAVs on disk, and
/// the bin Music with the item Jingle: the range 0 to 96,000 of Host, so the clip a.
@Suite(.serialized) @MainActor struct BinsSegmentTests {
    let folder: TemporaryFolder
    let defaults: UserDefaults
    let suite = "BinsSegmentTests.\(UUID().uuidString)"
    let app: AppDelegate

    init() throws {
        folder = try TemporaryFolder()
        defaults = try #require(UserDefaults(suiteName: suite))
        app = AppDelegate(recordings: nil, defaults: defaults)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func package(bins: Bool) async throws -> URL {
        let url = folder.url.appending(path: "b-\(UUID().uuidString).dirigible")
        try await Task.detached {
            try Session.create(at: url, sampleRate: 48_000)
            var session = Session(sampleRate: 48_000)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            for id in ["fa", "fb", "fc"] {
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000))
                buffer.frameLength = 480_000
                let writer = try ClipWriter(
                    url: url.appending(path: "\(clipsFolderName)/\(id).wav"), file: "\(id).wav", format: format)
                try writer.write(buffer)
                try writer.close()
                try session.addFile(AudioFile(id: FileID(id), path: "\(id).wav", layout: .mono, length: 480_000))
            }
            try session.addTrack("t1", name: "Host", layout: .mono)
            try session.addTrack("t2", name: "Guest", layout: .mono)
            try session.place(Clip(id: "a", file: "fa", start: 0, offset: 0, length: 96_000), on: "t1")
            try session.place(Clip(id: "b", file: "fb", start: 48_000, offset: 0, length: 96_000), on: "t2")
            try session.place(Clip(id: "c", file: "fc", start: 192_000, offset: 0, length: 96_000), on: "t1")
            if bins {
                try session.addBin("bin1", named: "Music")
                try session.addItem(
                    try session.excerpt(of: 0..<96_000, on: ["t1"]), named: "Jingle", to: "bin1", id: "item1")
            }
            try session.write(to: url)
        }.value
        return url
    }

    /// The window, with the pane at `segment`, or hidden for nil, in `app` or the app of the suite.
    func open(_ segment: PaneSegment? = .bins, bins: Bool = true, in app: AppDelegate? = nil) async throws -> (
        SessionWindow, Studio, NSWindow
    ) {
        let (model, studio, window, _) = try await openLanes(app ?? self.app, try await package(bins: bins))
        switch segment {
        case .bins?: model.toggleBins()
        case .index?: model.toggleIndex()
        case nil: break
        }
        await until("the window lays out") {
            window.contentView?.layoutSubtreeIfNeeded()
            return switch segment {
            case .bins?: !bins || model.leadingPane.binsTable != nil
            case .index?: model.leadingPane.table != nil
            case nil: !model.leadingPane.shown
            }
        }
        return (model, studio, window)
    }

    func paneSize(_ window: NSWindow, to width: Double) async {
        window.setContentSize(NSSize(width: width, height: 600))
        await until("the window takes \(width) pt") {
            window.contentView?.layoutSubtreeIfNeeded()
            return window.contentLayoutRect.width == width
        }
    }

    @Test func addToBinNeedsSelection() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = try await open(nil)
        #expect(!model.canAddToBin, "Add to Bin is on with no selection")
        model.timeline.selection = .range(Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"]))
        #expect(model.canAddToBin, "Add to Bin is off with a range")
        model.timeline.selection = .clips(ClipSet("b"))
        #expect(model.canAddToBin, "Add to Bin is off with a clip set")
        await model.close()
    }

    @Test func showBinsPicksTheBinsSegment() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = try await open(.index)
        model.toggleBins()
        #expect(model.leadingPane.shown && model.leadingPane.segment == .bins, "a show at Index switches to Bins")
        #expect(defaults.string(forKey: LeadingPaneState.segmentKey) == "bins", "the segment is an app preference")
        model.toggleBins()
        #expect(!model.leadingPane.shown, "Show Bins hides the pane while it shows Bins")
        model.toggleBins()
        #expect(model.leadingPane.shown && model.leadingPane.segment == .bins)
        await model.close()
    }

    @Test func showIndexAtBinsSwitchesToIndex() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = try await open(.bins)
        model.run(.toggleIndex)
        #expect(model.leadingPane.shown, "Show Session Index at Bins hid the pane")
        #expect(model.leadingPane.segment == .index)
        await model.close()
    }

    @Test func aToolbarClickAtBinsHidesThePane() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = try await open(.bins)
        let button = try #require(toolbarButton(model))
        await until("the item is enabled") { button.isEnabled }
        button.performClick(nil)
        #expect(!model.leadingPane.shown, "a click on the pane at Bins did not hide it")
        #expect(model.leadingPane.segment == .bins, "a hide keeps the segment")
        await model.close()
    }

    @Test func theToolbarItemShowsTheLastSegment() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = try await open(.bins)
        model.toggleBins()
        try #require(!model.leadingPane.shown)
        let button = try #require(toolbarButton(model))
        await until("the item is enabled") { button.isEnabled }
        button.performClick(nil)
        #expect(model.leadingPane.shown && model.leadingPane.segment == .bins, "the toolbar showed Index")
        model.run(.toggleSidebar)
        await model.close()

        // A new window reads the last segment of the app.
        let (other, _, _, _) = try await openLanes(app, try await package(bins: true))
        try #require(!other.leadingPane.shown, "the pane was hidden last")
        other.run(.toggleSidebar)
        #expect(other.leadingPane.shown && other.leadingPane.segment == .bins)
        await other.close()
    }

    @Test func theToolbarItemNamesTheSidebar() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let english = try stringsTable("en")
        let text: (L10n) -> String = { english[$0.rawValue] ?? $0.rawValue }
        #expect(text(ToolbarItemID.index.label) == "Sidebar")
        #expect(indexTooltip(shown: false, text: text) == "Show Sidebar")
        #expect(indexTooltip(shown: true, text: text) == "Hide Sidebar")

        let (model, _, _) = try await open(.index)
        let chrome = try #require(model.chrome)
        let item = try #require(chrome.toolbar.items.first { $0.itemIdentifier == ToolbarItemID.index.identifier })
        let button = try #require(item.view as? NSButton)
        await until("the item shows the pane") { button.state == .on && item.toolTip == indexTooltip(shown: true) }
        model.selectSegment(.bins)
        await runLoopPass()
        #expect(item.toolTip == indexTooltip(shown: true) && button.accessibilityLabel() == indexTooltip(shown: true))
        #expect(item.label == ToolbarItemID.index.label.text, "a segment switch changed the label")
        await model.close()
    }

    @Test func findInIndexAtBinsSwitchesToIndex() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, window) = try await open(.bins)
        model.findInIndex()
        #expect(model.leadingPane.shown && model.leadingPane.segment == .index, "Find left the pane at Bins")
        await until("the search field takes the focus") {
            guard let field = model.leadingPane.searchField else { return false }
            return (window.firstResponder as? NSTextView)?.delegate === field
        }
        await model.close()
    }

    @Test func aHideAtBinsGivesTheFocusToTheLanes() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, window) = try await open(.bins)
        let table = try #require(model.leadingPane.binsTable)
        try #require(window.makeFirstResponder(table))
        model.toggleBins()
        #expect(window.firstResponder === model.timelineView?.lanes, "the focus stayed in the removed list")
        await model.close()
    }

    @Test func theBinsSegmentBuildsNoIndexRows() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, _) = try await open(.bins)
        model.addTrack()
        await until("the track is added") { studio.session.tracks.count == 3 }
        #expect(model.leadingPane.builds == 0 && model.leadingPane.table == nil, "the Bins segment built index rows")
        model.selectSegment(.index)
        await until("the index builds its rows") { model.leadingPane.builds == 1 }
        await model.close()
    }

    @Test func segmentsShareOneWidth() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, window) = try await open(.index)
        await paneSize(window, to: 1300)
        model.leadingPane.width = IndexWidth(260)
        let frame = window.frame
        model.selectSegment(.bins)
        await until("the Bins list shows") { model.leadingPane.binsTable != nil }
        #expect(model.leadingPane.width.points == 260, "the switch changed the width")
        #expect(window.frame == frame, "the switch changed the window frame")
        #expect(defaults.object(forKey: "view.bins.width") == nil, "a second width key")
        await model.close()
    }

    @Test func binsPaneKeepsTheLanesMinimum() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, window) = try await open(nil)
        await paneSize(window, to: 1300)
        model.toggleBins()
        model.leadingPane.width = IndexWidth(260)
        model.toggleInspector()
        model.inspectorWidth = InspectorWidth(270)
        #expect(model.paneMinimum == 720 + 260 + 270, "the minimum counts the pane at Bins")
        model.dragInspector(.down(x: 0, clicks: 1))
        model.dragInspector(.drag(x: 300))
        model.dragInspector(.up)
        #expect(model.inspectorWidth.points == 320, "the inspector stops at 1300 - 720 - 260")
        await model.close()
    }

    @Test func showBinsTitleFlips() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = try await open(nil)
        #expect(app.binsItem(for: model).title == .menuViewBinsShow)
        model.toggleIndex()
        #expect(app.binsItem(for: model).title == .menuViewBinsShow, "Hide Bins while the pane shows Index")
        #expect(app.indexItem(for: model).title == .menuViewIndexHide)
        model.toggleBins()
        #expect(app.binsItem(for: model).title == .menuViewBinsHide)
        #expect(app.indexItem(for: model).title == .menuViewIndexShow, "Hide Session Index while the pane shows Bins")
        #expect(!MenuKeys.system.contains(MenuKeys.showBins))
        #expect(MenuKeys.all.filter { $0 == MenuKeys.showBins }.count == 1, "another item has Option-Command-C")
        await model.close()
    }

    @Test func addToBinSubmenuListsBins() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, _) = try await open(nil)
        model.edit(ripple: false) { session throws(SessionError) in _ = try session.addBin("bin0", named: "Ads") }
        try studio.edit(ripple: false) { session throws(SessionError) in try session.moveBin("bin0", to: 0) }
        #expect(model.addToBinItems.map(\.title) == ["Ads", "Music"], "the submenu is out of bin order")
        model.timeline.selection = .range(Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"]))
        model.addToBin("bin1")
        #expect(studio.session.bins.map { $0.items.count } == [0, 2], "the item went to another bin")
        model.finishBinRename(save: false)
        model.addToBin(nil)
        #expect(studio.session.bins.map(\.name) == ["Ads", "Music", L10n.binsNewName.format(3)], "New Bin made no bin")
        #expect(studio.session.bins.last?.items.count == 1, "New Bin added nothing")
        await model.close()
    }

    @Test func noBinTextSaysClipboard() throws {
        let english = try stringsTable("en")
        let keys: [L10n] = [
            .indexSegmentBins, .menuViewBinsShow, .menuViewBinsHide, .menuEditAddToBin, .binsNew, .binsNewName,
            .binsEmpty, .binsEmptyHint, .binsPaste, .binsInsert, .binsRename, .binsRemove, .binsMissing,
            .binsShort, .binsUnreadable, .errorBinMissing, .errorBinShort, .errorBinUnreadable, .toolbarSidebar,
            .toolbarSidebarShow, .toolbarSidebarHide, .menuEditAddToFavorites, .favoritesBanner,
            .errorFavoritesLocked, .errorFavoritesDamaged, .errorFavoritesNewer, .errorFavoritesFile,
            .errorFavoritesFileOther, .errorFavoritesSpace, .errorFavoritesCopy, .errorFavoritesSource,
            .errorFavoritesDownload, .errorFavoritesYielded, .favoritesTitle, .favoritesEmpty, .favoritesEmptyHint,
            .alertFavoritesRemove, .alertFavoritesRemoveBody, .alertFavoritesRemoveConfirm,
        ]
        for key in keys {
            let value = try #require(english[key.rawValue], "no English value for \(key.rawValue)")
            #expect(!value.localizedCaseInsensitiveContains("clipboard"), "\(key.rawValue): \(value)")
        }
    }

    /// C22: Edit > Add to Favorites has no key, and Option-Command-0 stays View > Reset Waveform Zoom.
    /// The menu bar is SwiftUI, so the test reads the item in `DirigibleApp.swift`.
    @Test func addToFavoritesKeepsTheWaveformResetKey() throws {
        let items = TimelineCommand.viewItems + TimelineCommand.pasteboardItems + TimelineCommand.editItems
        let zero = items.filter { $0.key.character == "0" && $0.modifiers == [.command, .option] }
        #expect(zero.map(\.command) == [.waveformZoomReset], "Option-Command-0 is Reset Waveform Zoom")
        #expect(!MenuKeys.all.contains(KeyboardShortcut("0", modifiers: [.command, .option])))
        let source = try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
                .appending(path: "../../Sources/DirigibleApp/DirigibleApp.swift").standardized, encoding: .utf8)
        let lines = source.split(separator: "\n").map(String.init)
        let item = lines.indices.filter { lines[$0].contains("L10n.menuEditAddToFavorites") }
        #expect(item.count == 1, "the Edit menu has one Add to Favorites item")
        let statement = item.flatMap { lines[$0...min($0 + 1, lines.count - 1)] }.joined()
        #expect(!item.isEmpty && !statement.contains("keyboardShortcut"), "Add to Favorites has no key: \(statement)")
    }

    @Test func templateLineCountsBinClips() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = try await package(bins: true)
        var session = try Session(contentsOf: url)
        try session.removeClips(["a", "b", "c"])
        let episode = try session.newEpisode()
        let keeps = await templateKeeps(of: episode, in: url)
        let size = try FileManager.default.attributesOfItem(atPath: url.appending(path: "Clips/fa.wav").path)[.size]
        #expect(keeps.clips == 1, "the bin clip is not counted")
        #expect(keeps.bytes == (size as? NSNumber)?.int64Value, "the size is not that of the bin WAV")
    }

    func toolbarButton(_ model: SessionWindow) -> NSButton? {
        model.chrome?.toolbar.items.first { $0.itemIdentifier == ToolbarItemID.index.identifier }?.view as? NSButton
    }
}
