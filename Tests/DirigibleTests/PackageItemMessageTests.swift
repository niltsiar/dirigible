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
            ("en", "\u{201C}Capture\u{201D} in this package couldn't be read (error 13)."),
            ("es", "No se puede leer \u{AB}Capture\u{BB} de este paquete (error 13)."),
        ] {
            let format = try #require(try stringsTable(language)[L10n.errorFileItemRead.rawValue])
            #expect(String(format: format, "Capture", 13) == text, "\(language)")
        }
    }

    /// An item that the open refuses: a link, a special file, or an item of the wrong kind, with
    /// what the user can do.
    @Test func anUnsafeItemSaysWhatToDo() throws {
        let error = StudioError.file(.unsafeItem("Clips"))
        #expect(L10n.message(for: error) == L10n.errorFileItem.rawValue)
        for (language, text) in [
            (
                "en",
                "The package can't be opened. \u{201C}Clips\u{201D} is a link, a special file, or an item of the "
                    + "wrong kind. Replace that item with a plain file or folder, or remove it."
            ),
            (
                "es",
                "No se puede abrir el paquete. \u{AB}Clips\u{BB} es un enlace, un archivo especial o un elemento de un "
                    + "tipo incorrecto. Sustituye ese elemento por un archivo o una carpeta normal, o elimínalo."
            ),
        ] {
            let format = try #require(try stringsTable(language)[L10n.errorFileItem.rawValue])
            #expect(String(format: format, "Clips") == text, "\(language)")
        }
    }
}
