import DirigibleAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp

/// The Favorites store in the app (F23, decision 0081): its window texts.
@Suite(.serialized) @MainActor struct FavoritesModelTests {
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
