import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The Favorites section of the Bins list (F23). Each window gets a temporary store through
/// `AppDelegate(favorites:)`. The favorite Sting is a copy of 48,000 to 96,000 of Guest (the clip b),
/// 1 s long, in the store group Favorites.
extension BinsSegmentTests {
    /// The window at Bins with Sting selected, the list focused, the playhead at 300,000, the empty
    /// range at the playhead on Host, and a route menu that also has Delete.
    struct FavoriteWindow {
        let model: SessionWindow
        let studio: Studio
        let window: NSWindow
        let route: RouteMenu
        let beeps: () -> Int
        let app: AppDelegate
        let store: URL
        let sting: BinItemID
    }

    /// A store with Sting in a new folder; nil for no item, so the store path does not exist.
    func favoritesStore(items: Bool = true) async throws -> (store: URL, sting: BinItemID?) {
        let store = folder.url.appending(path: "f-\(UUID().uuidString)/Favorites.dirigible")
        guard items else { return (store, nil) }
        let source = try await package(bins: false)
        let sting = try await Task.detached {
            let excerpt = try Session(contentsOf: source).excerpt(of: 48_000..<96_000, on: ["t2"])
            return try Favorites.add(
                Clipboard(excerpt, package: source, origin: nil), from: source, named: "Sting", bin: nil, store: store,
                log: { .disabled })
        }.value
        return (store, sting)
    }

    /// An app of the suite defaults with `store`, read once.
    func favoritesApp(_ store: URL) async -> AppDelegate {
        let app = AppDelegate(recordings: nil, defaults: defaults, favorites: store)
        await app.favorites.reload()
        return app
    }

    func rows(_ model: SessionWindow) -> [BinsRow] { model.leadingPane.binsTable?.source?.rows ?? [] }

    func focusedFavorite() async throws -> FavoriteWindow {
        let (store, found) = try await favoritesStore()
        let sting = try #require(found)
        let app = await favoritesApp(store)
        let (model, studio, window) = try await open(.bins, in: app)
        app.key = model
        var beeps = 0
        model.beep = { beeps += 1 }
        await studio.perform(.seek(.frame(300_000)))
        model.timeline.selection = .range(Marks(inPoint: 300_000, outPoint: 300_000, tracks: ["t1"]))
        await until("the list shows Sting") { rows(model).contains { $0.pick == .favorite(sting) } }
        model.selectBinItem(.favorite(sting))
        let table = try #require(model.leadingPane.binsTable)
        try #require(window.makeFirstResponder(table))
        try #require(model.binsListHasFocus(in: window))
        let route = RouteMenu([.addMarker, .markerInfo, .renameTrack, .delete])
        route.route = { command, event in app.timeline(command, event: event, in: window) }
        return FavoriteWindow(
            model: model, studio: studio, window: window, route: route, beeps: { beeps }, app: app, store: store,
            sting: sting)
    }

    /// C31: a session with no bin shows the Favorites section under "No Bins".
    @Test func favoritesShowWithNoBin() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, found) = try await favoritesStore()
        let app = await favoritesApp(store)
        let sting = try #require(app.favorites.bins.first?.items.first { $0.id == found })
        let (model, _, _) = try await open(.bins, bins: false, in: app)
        await until("the list shows the Favorites section") { model.leadingPane.binsTable != nil }
        #expect(rows(model) == [.favoritesHeader, .favorite(sting, rate: 48_000)], "the section lists the favorite")
        await model.close()
    }

    /// C23: with a favorite selected, Command-Return pastes it at the playhead, Shift-Return inserts it,
    /// and Return opens its rename, through the menu keys of the window.
    @Test func favoriteKeysPasteAndInsert() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let f = try await focusedFavorite()
        let files = f.studio.session.files.count
        f.route.press(chord("\r", code: 36, .command, in: f.window), in: f.window)
        await until("the paste ends") { f.model.importJob == nil }
        #expect(starts(f.studio, "t1") == [0, 192_000, 300_000], "Command-Return did not paste the favorite")
        #expect(f.studio.session.files.count == files + 1, "the paste did not copy the favorite into the session")
        f.route.press(chord("\r", code: 36, .shift, in: f.window), in: f.window)
        await until("the insert ends") { f.model.importJob == nil }
        #expect(starts(f.studio, "t1") == [0, 192_000, 300_000, 348_000], "Shift-Return did not insert the favorite")
        #expect(starts(f.studio, "t2") == [48_000], "an insert at 300,000 moved an earlier clip")
        f.route.press(chord("\r", code: 36, [], in: f.window), in: f.window)
        #expect(f.model.leadingPane.binRename == .favorite(f.sting), "Return did not open the rename of the favorite")
        #expect(
            f.studio.session.markers.isEmpty && f.beeps() == 0 && f.model.renamingTrack == nil, "a key hit the lanes")
        await f.model.close()
    }

    /// C26: Delete on a favorite asks, and never deletes the timeline selection or a session item.
    @Test func deleteOnAFavoriteLeavesTheTracks() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let f = try await focusedFavorite()
        f.model.timeline.selection = .range(Marks(inPoint: 24_000, outPoint: 72_000, tracks: ["t1"]))
        let tracks = f.studio.session.tracks
        f.route.press(chord("\u{8}", code: 51, [], in: f.window), in: f.window)
        #expect(f.model.alert == .confirmRemoveFavorite(.item(f.sting), name: "Sting"), "Delete did not ask")
        #expect(f.studio.session.tracks == tracks, "Delete on a favorite deleted the timeline selection")
        f.model.alert = nil
        #expect(f.studio.session.tracks == tracks, "Cancel changed the tracks")
        f.model.confirmRemoveFavorite(.item(f.sting))
        await until("the store drops Sting") { f.app.favorites.bins.allSatisfy(\.items.isEmpty) }
        #expect(f.studio.session.tracks == tracks, "Remove changed the tracks")
        #expect(f.studio.session.bins.first?.items.map(\.id) == ["item1"], "Delete removed a session item")
        await f.model.close()
    }

    /// C26: Cancel changes no byte of the store, and Remove removes the favorite. A group asks with the
    /// same alert.
    @Test func deleteFavoriteAsks() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let f = try await focusedFavorite()
        let xml = f.store.appending(path: "session.xml")
        let before = try Data(contentsOf: xml)
        #expect(f.model.binsCommand(.delete, isKey: true), "the list did not take Delete")
        #expect(f.model.alert == .confirmRemoveFavorite(.item(f.sting), name: "Sting"), "a removal with no question")
        f.model.alert = nil
        #expect(try Data(contentsOf: xml) == before, "Cancel changed the store")
        #expect(f.app.favorites.bins.first?.items.map(\.id) == [f.sting])

        f.model.confirmRemoveFavorite(.item(f.sting))
        await until("the store drops Sting") { f.app.favorites.bins.allSatisfy(\.items.isEmpty) }
        #expect(try Session(contentsOf: f.store).bins.flatMap(\.items).isEmpty, "Remove kept the favorite")
        await until("the pane drops the removed favorite") { f.model.leadingPane.selectedBinItem == nil }

        _ = try await f.app.favorites.edit { session throws(SessionError) in try session.addBin(named: "Jingles") }
        let jingles = try #require(f.app.favorites.bins.last)
        await until("the list shows the groups") { rows(f.model).contains(.favoriteGroup(jingles)) }
        let source = try #require(f.model.leadingPane.binsTable?.source)
        let row = try #require(rows(f.model).firstIndex(of: .favoriteGroup(jingles)))
        let menu = try #require(source.contextMenu(row: row))
        #expect(menu.items.map(\.title) == [L10n.binsRename.text, L10n.binsRemove.text])
        menu.performActionForItem(at: 1)
        #expect(
            f.model.alert == .confirmRemoveFavorite(.group(jingles.id), name: "Jingles"),
            "a group removal with no question")
        f.model.confirmRemoveFavorite(.group(jingles.id))
        await until("the store drops Jingles") { f.app.favorites.bins.count == 1 }
        await f.model.close()
    }

    /// C23, C30: the row of a favorite is one element, and its context menu and VoiceOver actions do what
    /// its keys do.
    @Test func favoriteRowActionsMatchTheKeys() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let f = try await focusedFavorite()
        let row = try #require(rows(f.model).firstIndex { $0.pick == .favorite(f.sting) })
        let cell = try itemCell(f.model, row: row)
        #expect(cell.isAccessibilityElement() && cell.accessibilityLabel() == "Sting, 0:01")
        let actions = cell.accessibilityCustomActions() ?? []
        #expect(actions.map(\.name) == [L10n.binsPaste.text, L10n.binsInsert.text, L10n.binsRename.text])
        let source = try #require(f.model.leadingPane.binsTable?.source)
        let menu = try #require(source.contextMenu(row: row))
        #expect(menu.items.map(\.title) == actions.map(\.name) + [L10n.binsRemove.text])

        menu.performActionForItem(at: 0)
        await until("the paste ends") { f.model.importJob == nil }
        #expect(starts(f.studio, "t1") == [0, 192_000, 300_000], "Paste at Playhead differs from Command-Return")
        _ = actions[1].handler?()
        await until("the insert ends") { f.model.importJob == nil }
        #expect(
            starts(f.studio, "t1") == [0, 192_000, 300_000, 348_000], "Insert at Playhead differs from Shift-Return")
        _ = actions[2].handler?()
        #expect(f.model.leadingPane.binRename == .favorite(f.sting), "the action Rename differs from Return")
        await f.model.close()
    }

    /// C25: after Add to Favorites, the new favorite is selected, and its rename opens prefilled with the
    /// first track name only.
    @Test func favoritePrefillsTheTrackName() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, _) = try await favoritesStore(items: false)
        let app = await favoritesApp(store)
        let (model, _, window) = try await open(nil, in: app)
        model.timeline.selection = .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        model.addToFavorites()
        await until("the add ends") { model.importJob == nil }
        let added = try #require(app.favorites.bins.first?.items.first)
        #expect(added.name == "Host", "the prefilled name")
        #expect(model.leadingPane.shown && model.leadingPane.segment == .bins, "the add did not show the bins")
        #expect(model.leadingPane.selectedBinItem == .favorite(added.id), "the new favorite is not selected")
        #expect(model.leadingPane.binRename == .favorite(added.id), "no rename of the new favorite")
        let editor = try await renameEditor(model, window)
        #expect(editor.string == "Host" && editor.selectedRange() == NSRange(location: 0, length: 4))
        editor.insertText("Bed", replacementRange: NSRange(location: 0, length: 4))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await until("the store has the typed name") { app.favorites.bins.first?.items.first?.name == "Bed" }
        #expect(model.leadingPane.selectedBinItem == .favorite(added.id), "the commit lost the selection")
        await model.close()
    }

    /// C28: one store group shows flat; from the second group, each group has its row.
    @Test func favoritesFlatWithOneBin() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, found) = try await favoritesStore()
        let app = await favoritesApp(store)
        let sting = try #require(app.favorites.bins.first?.items.first { $0.id == found })
        let (model, _, _) = try await open(.bins, in: app)
        await until("the list shows Sting") { rows(model).last == .favorite(sting, rate: 48_000) }
        #expect(
            Array(rows(model).suffix(2)) == [.favoritesHeader, .favorite(sting, rate: 48_000)], "one group is flat")

        _ = try await app.favorites.edit { session throws(SessionError) in try session.addBin(named: "Jingles") }
        let groups = app.favorites.bins
        try #require(groups.count == 2)
        await until("the list shows the groups") { rows(model).last == .favoriteGroup(groups[1]) }
        #expect(
            Array(rows(model).suffix(4)) == [
                .favoritesHeader, .favoriteGroup(groups[0]), .favorite(sting, rate: 48_000), .favoriteGroup(groups[1]),
            ], "two groups each have a row")
        await model.close()
    }

    /// C31: a store that does not exist shows "No Favorites" with the menu path of the add, and the read
    /// makes no store.
    @Test func emptyFavoritesShowsTheKey() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, _) = try await favoritesStore(items: false)
        let app = await favoritesApp(store)
        let (model, _, _) = try await open(.bins, in: app)
        await until("the list shows the note") { rows(model).last == .favoritesNote(nil) }
        #expect(Array(rows(model).suffix(2)) == [.favoritesHeader, .favoritesNote(nil)])
        let table = try #require(model.leadingPane.binsTable)
        let last = try #require(rows(model).indices.last)
        let cell = try #require(table.view(atColumn: 0, row: last, makeIfNecessary: true) as? FavoritesNoteCell)
        #expect(
            cell.textField?.stringValue == L10n.favoritesEmpty.text
                && cell.detail.stringValue == L10n.favoritesEmptyHint.text)
        let english = try stringsTable("en")
        #expect(english[L10n.favoritesEmpty.rawValue] == "No Favorites")
        #expect(
            english[L10n.favoritesEmptyHint.rawValue]?.contains("Edit > Add to Favorites") == true,
            "the hint names the menu path")
        #expect(
            !FileManager.default.fileExists(atPath: store.deletingLastPathComponent().path), "the read made a store")
        await model.close()
    }

    /// C38: a damaged store shows one fault row, and the session rows keep their keys.
    @Test func damagedFavoritesKeepTheBinsList() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = folder.url.appending(path: "damaged/Favorites.dirigible")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data("not a session".utf8).write(to: store.appending(path: "session.xml"))
        let app = await favoritesApp(store)
        let fault = StudioError.favoritesDamaged(.malformedXML)
        try #require(app.favorites.state == .fault(fault))
        let (model, studio, window, route, _) = try await focusedList(in: app)
        await until("the list shows the fault row") { rows(model).last == .favoritesNote(fault) }
        let table = try #require(model.leadingPane.binsTable)
        let last = try #require(rows(model).indices.last, "the fault cleared the rows of the session")
        let cell = try #require(table.view(atColumn: 0, row: last, makeIfNecessary: true) as? FavoritesNoteCell)
        #expect(cell.detail.stringValue == L10n.message(for: fault), "the row shows the text of the fault")
        route.press(chord("\r", code: 36, .command, in: window), in: window)
        #expect(starts(studio, "t1") == [0, 192_000, 300_000], "Command-Return on a session item did not paste")
        #expect(model.alert == nil, "a damaged store shows an alert")
        await model.close()
    }
}
