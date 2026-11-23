import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Favorites in a studio (F23, decision 0081): the store faults of an add or an edit as `StudioError`.
struct StudioFavoritesTests {
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
