import DirigibleAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp

/// The Favorites store in the app (F23, decision 0081): no store in a test app, the read of a missing
/// or damaged store, the reload after a write, and the window texts.
@Suite(.serialized) @MainActor struct FavoritesModelTests {
    let folder: TemporaryFolder
    /// A store with one empty bin "Favorites".
    let store: URL

    init() throws {
        folder = try TemporaryFolder()
        store = folder.url.appending(path: "Favorites.dirigible")
        try writeStore()
    }

    func writeStore() throws {
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        var session = Session(sampleRate: 48_000)
        _ = try session.addBin(named: "Favorites")
        try session.write(to: store)
    }

    var empty: FavoritesModel.State { .loaded(Session(sampleRate: 48_000)) }

    /// C35: an app that a test makes has no store, so it reads and writes none; a model with a store
    /// reads it.
    @Test func aTestAppHasNoStore() async throws {
        let app = AppDelegate(recordings: nil)
        await app.favorites.reload()
        #expect(!app.favorites.canAdd && app.favorites.state == empty, "a test app has no store")
        let edited = try await app.favorites.edit { session throws(SessionError) in try session.addBin(named: "X") }
        #expect(edited == nil && app.favorites.bins.isEmpty, "an edit with no store does nothing")

        let model = FavoritesModel(store: store)
        await model.reload()
        #expect(model.canAdd && model.bins.map(\.name) == ["Favorites"], "a model with a store reads it")
    }

    /// C38: a store folder with no `session.xml`, and no store folder, read as an empty store.
    @Test func missingStoreReadsEmpty() async throws {
        let model = FavoritesModel(store: store)
        await model.reload()
        #expect(model.bins.map(\.name) == ["Favorites"], "the store reads")

        try FileManager.default.removeItem(at: store.appending(path: "session.xml"))
        await model.reload()
        #expect(model.state == empty, "a folder with no session.xml is an empty store")

        try writeStore()
        await model.reload()
        #expect(model.bins.count == 1)
        try FileManager.default.removeItem(at: store)
        await model.reload()
        #expect(model.state == empty, "no store folder is an empty store")
    }

    /// C38: a `session.xml` that does not parse gives the fault state and no list; a later reload
    /// of a good store gives the list again.
    @Test func damagedStoreShowsItsFault() async throws {
        let model = FavoritesModel(store: store)
        try Data("not a session".utf8).write(to: store.appending(path: "session.xml"))

        await model.reload()

        #expect(model.state == .fault(.favoritesDamaged(.malformedXML)) && model.bins.isEmpty)
        try writeStore()
        await model.reload()
        #expect(model.bins.map(\.name) == ["Favorites"], "a later reload shows the list again")
    }

    /// C18: after a store edit of the app, the model lists the new store with no other reload. A
    /// refused edit changes nothing and throws its session refusal.
    @Test func reloadAfterWrite() async throws {
        let model = FavoritesModel(store: store)
        await model.reload()
        let bin = try #require(model.bins.first?.id)

        let renamed: Void? = try await model.edit { session throws(SessionError) in
            try session.renameBin(bin, to: "Jingles")
        }

        #expect(renamed != nil && model.bins.map(\.name) == ["Jingles"], "the model lists the edit")
        #expect(try Session(contentsOf: store).bins.map(\.name) == ["Jingles"])
        await #expect(throws: StudioError.session(.unknownBinItem("gone"))) {
            try await model.edit { session throws(SessionError) in try session.removeItem("gone") }
        }
        #expect(model.bins.map(\.name) == ["Jingles"])
    }

    /// C37: the English window text of each store fault names Favorites, not the session.
    @Test func storeFaultTextsNameFavorites() async throws {
        let faults: [StudioError] = [
            .favoritesLocked, .favoritesDamaged(.malformedXML), .favoritesDamaged(.unsupportedVersion(99)),
            .favoritesDamaged(nil), .favoritesFile(.readFailed(errno: EIO)), .favoritesFile(.packageMoved),
            .favoritesCopy(.space(needed: 2, free: 1)), .favoritesCopy(.write(file: "host.wav", errno: ENOSPC)),
            .favoritesCopy(.write(file: "host.wav", errno: EIO)),
            .favoritesCopy(.convert(file: "host.wav", errno: EIO)),
            .favoritesCopy(.sourceMissing(file: "host.wav")), .favoritesCopy(.sourceChanged(file: "host.wav")),
            .favoritesCopy(.notDownloaded(file: "host.wav")), .favoritesYielded,
        ]
        try await HeaderStateLineTests().withStrings("en") {
            #expect(L10n.message(for: .locked).contains("session"), "the English table is in use")
            for fault in faults {
                let text = L10n.message(for: fault)
                #expect(text.contains("Favorites") && !text.contains("this session open"), "\(fault): \(text)")
            }
        }
    }
}
