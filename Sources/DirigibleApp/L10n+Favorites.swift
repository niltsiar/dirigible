import DirigibleAudio
import DirigibleCore
import Foundation

/// The texts of the Favorites store faults (decision 0081): each one names Favorites, not the
/// session. The switches have no `default`.
extension L10n {
    /// The text of a store that does not read as a session of this build.
    static func favoritesMessage(damaged error: SessionFileError?) -> String {
        if case .unsupportedVersion = error { return errorFavoritesNewer.text }
        return errorFavoritesDamaged.text
    }

    /// The text of another read or write fault of the store.
    static func favoritesMessage(file error: SessionFileError) -> String {
        switch error {
        case .readFailed(let code), .writeFailed(_, let code), .unreadableItem(_, let code):
            errorFavoritesFile.format(Int(code))
        case .unsupportedVersion: errorFavoritesNewer.text
        case .malformedXML, .invalidChannelCount, .missingAttribute, .invalidValue, .invalidSession:
            errorFavoritesDamaged.text
        case .locked: errorFavoritesLocked.text
        case .wouldNotReadBack, .packageMoved, .exists, .unsafeItem: errorFavoritesFileOther.text
        }
    }

    /// The text of a failed copy into the store. A source fault names this session and Favorites.
    static func favoritesMessage(copy error: PasteError) -> String {
        switch error {
        case .space, .write(_, ENOSPC): errorFavoritesSpace.text
        case .write(_, let code), .convert(_, let code): errorFavoritesCopy.format(Int(code))
        case .sourceMissing, .sourceChanged: errorFavoritesSource.text
        case .notDownloaded(let file): errorFavoritesDownload.format(file)
        // The window shows no alert for a Cancel.
        case .cancelled, .session: errorSessionOther.text
        }
    }
}
