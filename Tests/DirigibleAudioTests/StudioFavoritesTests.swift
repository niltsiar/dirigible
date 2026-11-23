import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Favorites in a studio (F23, decision 0081): the add as a blocking run of the source studio, the
/// one store writer, and the store faults of an add or an edit as `StudioError`. The source is P of
/// `PasteStudioFixture` (track t1, clip A of take1-mic), and the store is in its folder.
struct StudioFavoritesTests {
    /// The suite holds the fixture, so its folders last for the whole test.
    let fixture: PasteStudioFixture

    init() async throws { fixture = try await PasteStudioFixture.make() }

    @MainActor func open() async throws -> (Studio, FavoritesWriter, URL, PasteStudioFixture, Excerpt) {
        let studio = try await fixture.open(fixture.p)
        let store = fixture.p.folder.url.appending(path: "Favorites.dirigible")
        let excerpt = try studio.session.excerpt(of: 0..<48_000, on: ["t1"])
        return (studio, FavoritesWriter(store: store), store, fixture, excerpt)
    }

    /// C14: an add runs in the banner and changes no byte of the source. A Cancel before the
    /// renames, and a take in another studio, leave each store byte as it was.
    @MainActor @Test func addYieldsAndCancels() async throws {
        let (studio, writer, store, fixture, excerpt) = try await open()
        let (session, source) = (studio.session, try packageBytes(fixture.p.url))
        _ = try await studio.addToFavorites(excerpt, named: "Sting", writer: writer) { _ in }
        let before = try packageBytes(store)
        #expect(before.keys.sorted() == ["Clips/take1-mic.wav", "session.xml"], "the first add wrote the store")
        #expect(studio.session == session && !studio.canUndo, "an add records no undo entry")
        #expect(try packageBytes(fixture.p.url) == source, "an add changes no byte of the source")

        let gate = Gate(limit: Gate.openLimit)
        studio.environment.importStep = { gate.waitOnce() }
        let adding = Task { try await studio.addToFavorites(excerpt, named: "Bed", writer: writer) { _ in } }
        await gate.entered()
        #expect(studio.importRun?.kind == .favorite, "the add is a blocking run")
        adding.cancel()
        gate.open()
        await #expect(throws: StudioError.favoritesCopy(.cancelled)) { try await adding.value }
        #expect(try packageBytes(store) == before, "a Cancel before the renames changes no store byte")
        #expect(studio.session == session && studio.transport == .idle)

        let a = try await ExportStudioFixture.make()
        let hal = TestHAL([a.mic])
        let studioA = try await a.open(hal)
        let hold = Gate(limit: nil)
        studio.environment.importStep = { hold.waitOnce() }
        defer { hold.open() }
        let yielding = Task { try await studio.addToFavorites(excerpt, named: "Bed", writer: writer) { _ in } }
        await hold.entered()
        studioA.otherStudios = { [studio] }
        let start = Task { try await studioA.startTake(armed: ["t1"], devices: [a.mic], hostTimeNanos: takeStart) }
        await until(limit: .seconds(10), "the take did not start") { studioA.transport == .recording(take: 1) }
        hold.open()
        await #expect(throws: StudioError.favoritesYielded) { try await yielding.value }
        #expect(try packageBytes(store) == before, "a yielded add changes no store byte")
        _ = try await start.value
        try await StudioExportTests().recordAndStop(studioA, hal, from: takeStart)
    }

    /// C14 and U14: the studio session does not change, so the run removes its made files; the store
    /// keeps each WAV that its `session.xml` names.
    @MainActor @Test func finishedAddKeepsStoreFiles() async throws {
        let (studio, writer, store, _, excerpt) = try await open()
        let session = studio.session

        let id = try await studio.addToFavorites(excerpt, named: "Sting", writer: writer) { _ in }

        let read = try Session(contentsOf: store)
        let item = try #require(read.bins.flatMap(\.items).first { $0.id == id }, "the returned ID is stored")
        let paths = Set(item.lanes.flatMap(\.clips).compactMap { read.files[$0.file]?.path })
        #expect(paths == ["take1-mic.wav"])
        #expect(try clipNames(store) == ["take1-mic.wav"], "the WAV that session.xml names is in Clips")
        #expect(studio.session == session && !studio.canUndo && studio.transport == .idle)
    }

    /// C14: a Cancel after the store write reports the cancel, and the store keeps the favorite.
    @MainActor @Test func cancelAfterStoreWriteKeepsItem() async throws {
        let (studio, writer, store, _, excerpt) = try await open()
        studio.environment.importWorkDone = { await studio.cancelImport() }

        await #expect(throws: StudioError.favoritesCopy(.cancelled)) {
            try await studio.addToFavorites(excerpt, named: "Sting", writer: writer) { _ in }
        }

        let read = try Session(contentsOf: store)
        #expect(read.bins.flatMap(\.items).map(\.name) == ["Sting"], "the store keeps the favorite")
        #expect(try clipNames(store) == ["take1-mic.wav"], "and its WAV")
    }

    /// C36: an edit that starts while an add holds the store lock waits for the add on the one
    /// writer, then succeeds on the store with the added item.
    @MainActor @Test func editDuringAddRunsAfterTheAdd() async throws {
        let (studio, writer, store, _, excerpt) = try await open()
        let first = try await studio.addToFavorites(excerpt, named: "Sting", writer: writer) { _ in }
        let bin = try #require(try Session(contentsOf: store).bins.first?.id)
        let hold = Gate(limit: nil)
        studio.environment.importStep = { hold.waitOnce() }
        defer { hold.open() }
        let adding = Task { try await studio.addToFavorites(excerpt, named: "Bed", writer: writer) { _ in } }
        await hold.entered()

        let editing = Task {
            await writer.edit(log: .disabled) { session throws(SessionError) in
                try session.renameBin(bin, to: "Jingles")
            }
        }
        await until(limit: .seconds(10), "the edit did not wait for the writer") { writer.queued == 2 }
        hold.open()
        let second = try await adding.value
        if case .failure(let error) = await editing.value { Issue.record("the edit failed: \(error)") }

        let read = try Session(contentsOf: store)
        #expect(read.bins.map(\.name) == ["Jingles"], "the edit ran")
        #expect(read.bins.flatMap(\.items).map(\.id) == [first, second], "after the add")
    }

    /// C37: each `EditFailure` of `Favorites.add` and `Favorites.edit` gives a Favorites case, so the
    /// window text names the store, not the session. A refused edit body stays a session refusal.
    @Test func storeFailuresMapToFavoritesCases() {
        let damaged: [SessionFileError] = [
            .malformedXML, .unsupportedVersion(99), .invalidChannelCount(3),
            .missingAttribute(element: "clip", attribute: "file"), .invalidValue(element: "bins", attribute: "version"),
            .invalidSession(.unknownBinItem("x")),
        ]
        let other: [SessionFileError] = [
            .readFailed(errno: EIO), .writeFailed(step: "rename", errno: ENOSPC), .wouldNotReadBack(nil),
            .packageMoved, .exists, .unsafeItem("Clips"), .unreadableItem("Clips", errno: EACCES),
        ]
        var adds: [(EditFailure<PasteError>, StudioError)] = [
            (.file(.locked), .favoritesLocked), (.pendingTake, .favoritesDamaged(nil)),
            (.splitTake, .favoritesDamaged(nil)), (.body(.cancelled), .favoritesCopy(.cancelled)),
            (.body(.space(needed: 2, free: 1)), .favoritesCopy(.space(needed: 2, free: 1))),
            (.body(.sourceMissing(file: "host.wav")), .favoritesCopy(.sourceMissing(file: "host.wav"))),
        ]
        adds += damaged.map { (.file($0), .favoritesDamaged($0)) } + other.map { (.file($0), .favoritesFile($0)) }
        for (failure, expected) in adds {
            #expect(StudioError(favorites: failure) == expected, "add \(failure)")
        }
        let edits: [(EditFailure<SessionError>, StudioError)] = [
            (.file(.locked), .favoritesLocked),
            (.file(.readFailed(errno: ENOENT)), .favoritesFile(.readFailed(errno: ENOENT))),
            (.file(.malformedXML), .favoritesDamaged(.malformedXML)), (.pendingTake, .favoritesDamaged(nil)),
            (.body(.unknownBinItem("gone")), .session(.unknownBinItem("gone"))),
        ]
        for (failure, expected) in edits {
            #expect(StudioError(favorites: failure) == expected, "edit \(failure)")
        }
    }
}
