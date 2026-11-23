import DirigibleCore
import Foundation

extension StudioError {
    /// The fault of an add to the Favorites store. A refused add body is a copy fault.
    package init(favorites failure: EditFailure<PasteError>) {
        switch failure {
        case .file(let error): self = .init(favoritesFile: error)
        // A store never records, and its edits do not ripple.
        case .pendingTake, .splitTake: self = .favoritesDamaged(nil)
        case .body(let error): self = .favoritesCopy(error)
        }
    }

    /// The fault of a rename, a remove, or a new group in the Favorites store. A refused edit body,
    /// such as an unknown ID, is a session refusal.
    package init(favorites failure: EditFailure<SessionError>) {
        switch failure {
        case .file(let error): self = .init(favoritesFile: error)
        case .pendingTake, .splitTake: self = .favoritesDamaged(nil)
        case .body(let error): self = .session(error)
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
