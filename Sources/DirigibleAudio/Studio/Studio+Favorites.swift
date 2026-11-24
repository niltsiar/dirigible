import DirigibleCore
import Foundation

extension Studio {
    /// Adds a copy of `excerpt` of this studio to the Favorites store as an item named `name` in
    /// `bin` (decision 0081), and returns its ID. It is a blocking run, as a paste from another
    /// package (`blockingRun`): a take start in another studio stops it with `.favoritesYielded`, and
    /// a Cancel with `.favoritesCopy(.cancelled)`. `writer` runs the store write after each earlier
    /// store write of the app. The studio session does not change, so the run saves nothing and
    /// records no undo entry. A stop after the store write still throws, and the store keeps the
    /// item: the caller reads the store again on each result.
    package func addToFavorites(
        _ excerpt: Excerpt, named name: String, bin: BinID? = nil, writer: FavoritesWriter,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws(StudioError) -> BinItemID {
        let (clipboard, environment, log) = (clipboard(of: excerpt), environment, log)
        return try await blockingRun(
            name: url.deletingPathExtension().lastPathComponent, kind: .favorite,
            cancelled: .favoritesCopy(.cancelled), yielded: .favoritesYielded, ripple: false
        ) { session, lock, flags in
            let source: URL
            do throws(SessionFileError) { source = try lock.package() } catch { return .failure(.file(error)) }
            let added = await writer.add(
                clipboard, from: source, named: name, bin: bin, log: log,
                progress: { fraction in Task { @MainActor in progress(fraction) } },
                isCancelled: {
                    environment.importStep()
                    return flags.isCancelled
                }, whenCancelled: flags.whenCancelled)
            await environment.importWorkDone()
            // The store holds the new files, so the run gets none to remove.
            return added.map { (session, $0, made: []) }
        }
    }
}

extension StudioError {
    /// The fault of an add to the Favorites store. A refused add body is a copy fault.
    package init(favorites failure: EditFailure<PasteError>) {
        switch failure {
        case .file(let error): self = .init(favoritesFile: error)
        // A store never records, and its edits do not ripple.
        case .pendingTake, .splitTake: self = .favoritesDamaged(nil)
        case .body(let error): self = .favoritesCopy(error)
        case .archive(let fault): self = .archive(fault)
        }
    }

    /// The fault of a rename, a remove, or a new group in the Favorites store. A refused edit body,
    /// such as an unknown ID, is a session refusal.
    package init(favorites failure: EditFailure<SessionError>) {
        switch failure {
        case .file(let error): self = .init(favoritesFile: error)
        case .pendingTake, .splitTake: self = .favoritesDamaged(nil)
        case .body(let error): self = .session(error)
        case .archive(let fault): self = .archive(fault)
        }
    }

    /// A read or write fault of the store file: the lock, a file that does not read as a session of
    /// this build, or another fault.
    package init(favoritesFile error: SessionFileError) {
        switch error {
        case .locked: self = .favoritesLocked
        case .malformedXML, .unsupportedVersion, .invalidChannelCount, .missingAttribute, .invalidValue,
            .invalidSession:
            self = .favoritesDamaged(error)
        case .readFailed, .writeFailed, .wouldNotReadBack, .packageMoved, .exists, .unsafeItem, .unreadableItem:
            self = .favoritesFile(error)
        }
    }
}
