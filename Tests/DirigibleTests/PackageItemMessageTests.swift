import DirigibleAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp

/// The app texts of a package item that the open refuses (decision 0003), in English and Spanish.
/// The test process has no string table in `Bundle.main`, so `L10n.message` gives the key.
struct PackageItemMessageTests {
    /// An item that does not read: the text names the item, not the session file.
    @Test func anUnreadableItemNamesTheItem() throws {
        let error = StudioError.file(.unreadableItem("Capture", errno: EACCES))
        #expect(L10n.message(for: error) == L10n.errorFileItemRead.rawValue)
        for (language, text) in [
            ("en", "\u{201C}Capture\u{201D} in this package cannot be read (error 13)."),
            ("es", "No se puede leer \u{AB}Capture\u{BB} de este paquete (error 13)."),
        ] {
            let format = try #require(try stringsTable(language)[L10n.errorFileItemRead.rawValue])
            #expect(String(format: format, "Capture", 13) == text, "\(language)")
        }
    }
}
