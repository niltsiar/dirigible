import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Edit > Add to Favorites on a real session window (F23, C14, C35). The store is a temporary
/// package with one empty bin "Favorites"; a test app gets it only through `favorites:`.
@Suite(.serialized) @MainActor struct FavoritesWindowTests {
    let folder: TemporaryFolder
    let store: URL

    init() throws {
        folder = try TemporaryFolder()
        store = folder.url.appending(path: "Favorites.dirigible")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        var session = Session(sampleRate: 48_000)
        _ = try session.addBin(named: "Favorites")
        try session.write(to: store)
    }

    /// A key window of a package in `name` with tracks T1 and T2, and 0 to 1 s of T1 selected.
    func open(_ app: AppDelegate, in name: String = "a") async throws -> (SessionWindow, Studio) {
        let parent = folder.url.appending(path: name)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let package = try await timelinePackage(in: parent, tracks: 2, seconds: 2, audio: true)
        let (model, studio, _, _) = try await openLanes(app, package)
        model.timeline.selection = .range(Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"]))
        return (model, studio)
    }

    /// Holds the add at its first cancel read with no limit; `entered` is true while it waits. The test
    /// releases it in a `defer` too.
    func hold(_ studio: Studio) -> (entered: LockedFlag, release: DispatchSemaphore) {
        let (entered, release) = (LockedFlag(), DispatchSemaphore(value: 0))
        studio.environment.importStep = {
            guard !entered.value else { return }
            entered.value = true
            release.wait()
        }
        return (entered, release)
    }

    /// A bin that the store gets with no write of the app, so the model has not read it.
    func addBinOutsideTheApp(_ app: AppDelegate) throws {
        let addBin = { (session: inout Session) throws(SessionError) in try session.addBin(named: "Jingles") }
        _ = try Favorites.edit(store: store, log: { .disabled }, addBin)
        #expect(app.favorites.bins.map(\.name) == ["Favorites"], "the model has not read the new bin")
    }

    /// C35: with no store, Add to Favorites is off and does nothing; with a store, it adds the
    /// selection named after its first track (C25).
    @Test func noStoreTurnsOffAddToFavorites() async throws {
        let app = AppDelegate(recordings: nil)
        let (model, studio) = try await open(app)
        #expect(model.canAddToBin && !model.canAddToFavorites, "Add to Favorites is off with no store")
        model.addToFavorites()
        #expect(model.importJob == nil && studio.importRun == nil, "the add does nothing with no store")
        await model.close()

        let withStore = AppDelegate(recordings: nil, favorites: store)
        let (second, _) = try await open(withStore, in: "b")
        #expect(second.canAddToFavorites, "Add to Favorites is on with a store and a selection")
        second.addToFavorites()
        await until("the add ends") { second.importJob == nil }
        #expect(second.alert == nil)
        #expect(withStore.favorites.bins.flatMap(\.items).map(\.name) == ["T1"], "the window lists the favorite")
        await second.close()
    }

    /// C14: a Cancel of the add reads the store again, so the window lists a store change that the
    /// app did not make.
    @Test func cancelledAddReloadsStore() async throws {
        let app = AppDelegate(recordings: nil, favorites: store)
        await app.favorites.reload()
        let (model, studio) = try await open(app)
        try addBinOutsideTheApp(app)
        let (entered, release) = hold(studio)
        defer { release.signal() }

        model.addToFavorites()
        await until("the add holds") { entered.value }
        #expect(model.importJob != nil && studio.importRun?.kind == .favorite, "the add runs in the banner")
        model.cancelImport()
        release.signal()
        await until("the add ends") { model.importJob == nil }

        #expect(model.alert == nil, "a Cancel shows no alert")
        #expect(app.favorites.bins.map(\.name) == ["Favorites", "Jingles"], "the window read the store again")
        await sectionListsJingles(model)
        await model.close()
    }

    /// C14: a take in another studio stops the add, and the window reads the store again.
    @Test func yieldedAddReloadsStore() async throws {
        let app = AppDelegate(recordings: nil, favorites: store)
        await app.favorites.reload()
        let (model, studio) = try await open(app)
        try addBinOutsideTheApp(app)
        let (entered, release) = hold(studio)
        defer { release.signal() }

        model.addToFavorites()
        await until("the add holds") { entered.value }
        #expect(studio.endImport(.take), "the take start stops the add")
        release.signal()
        await until("the add ends") { model.importJob == nil }

        #expect(model.alert == nil, "a yield shows no alert")
        #expect(app.favorites.bins.map(\.name) == ["Favorites", "Jingles"], "the window read the store again")
        await sectionListsJingles(model)
        await model.close()
    }

    /// C18: when the app becomes active again, the window reads a store write of another process.
    @Test func activationReadsAnOutsideWrite() async throws {
        let app = AppDelegate(recordings: nil, favorites: store)
        await app.favorites.reload()
        let (model, _) = try await open(app)
        try addBinOutsideTheApp(app)

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        await until("the window reads Jingles") { app.favorites.bins.map(\.name) == ["Favorites", "Jingles"] }
        await model.close()
    }

    /// C18: a show of the Bins segment reads a store write of another process.
    @Test func binsShowReadsAnOutsideWrite() async throws {
        let app = AppDelegate(recordings: nil, favorites: store)
        await app.favorites.reload()
        let (model, _) = try await open(app)
        try addBinOutsideTheApp(app)

        await sectionListsJingles(model)
        await model.close()
    }

    /// C18: a newer reload that overlaps the reload after an add holds the add until its read lands,
    /// so the rename of the new favorite opens.
    @Test func overlappingReloadKeepsTheRename() async throws {
        let app = AppDelegate(recordings: nil, favorites: store)
        await app.favorites.reload()
        let (model, _) = try await open(app)
        #expect(!model.leadingPane.shown, "no Bins show reads the store")
        let (first, second, reads) = (AsyncGate(), AsyncGate(), LockedCount())
        app.favorites.readStep = {
            reads.add()
            switch reads.value {
            case 1: await first.wait()
            case 2: await second.wait()
            default: break
            }
        }
        defer {
            first.open()
            second.open()
        }

        model.addToFavorites()
        await first.entered()
        let newer = Task { await app.favorites.reload() }
        await second.entered()
        first.open()
        await until("the reload of the add ends or waits") { model.importJob == nil || !app.favorites.waiting.isEmpty }
        second.open()
        await newer.value
        await until("the add ends") { model.importJob == nil }

        let added = try #require(app.favorites.bins.first?.items.first)
        #expect(model.leadingPane.binRename == .favorite(added.id), "no rename of the new favorite")
        await model.close()
    }

    /// The Favorites section of the Bins list shows the group that the store got outside the app.
    func sectionListsJingles(_ model: SessionWindow) async {
        model.toggleBins()
        await until("the Favorites section lists Jingles") {
            let rows = model.leadingPane.binsTable?.source?.rows ?? []
            return rows.contains { if case .favoriteGroup(let bin) = $0 { bin.name == "Jingles" } else { false } }
        }
    }
}
