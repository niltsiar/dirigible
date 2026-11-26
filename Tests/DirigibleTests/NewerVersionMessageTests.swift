import DirigibleAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp

/// The app texts of a file of a newer version (decision 0024 P3), in English and Spanish. The test
/// process has no string table in `Bundle.main`, so `L10n.message` gives the key.
struct NewerVersionMessageTests {
    static let segment = SegmentName(stem: "take1-1-1")!

    /// `L10n.message` of `error` gives `key`, and the tables give `en` and `es` for it.
    func check(_ error: StudioError, _ key: L10n, en: String, es: String) throws {
        #expect(L10n.message(for: error) == key.rawValue)
        for (language, text) in [("en", en), ("es", es)] {
            let format = try #require(try stringsTable(language)[key.rawValue], "\(language) \(key.rawValue)")
            #expect(String(format: format, Self.segment.stem) == text, "\(language)")
        }
    }

    @Test func aNewerSidecarNamesTheNewerVersion() throws {
        try check(
            .segment(Self.segment, .newerSidecar(version: 2)), .errorSegmentNewer,
            en: "The audio take1-1-1 was made by a newer version of Dirigible. Update Dirigible to place it.",
            es: "El audio take1-1-1 se creó con una versión más nueva de Dirigible. Actualiza Dirigible para colocarlo."
        )
    }

    /// Criterion 6: a newer session file and a damaged session file have their own texts.
    @Test func aNewerSessionFileIsNotADamagedFile() throws {
        try check(
            .file(.unsupportedVersion(3)), .errorFileNewer,
            en: "This session was made by a newer version of Dirigible. Update Dirigible to open it.",
            es: "Esta sesión se creó con una versión más nueva de Dirigible. Actualiza Dirigible para abrirla.")
        try check(
            .file(.malformedXML), .errorFileUnreadable, en: "The session file is damaged.",
            es: "El archivo de la sesión está dañado.")
    }

    /// Code gate 1 item 3: a read fault of a take file (the anchor, a WAV read-back, `Capture/`)
    /// names the file and says that the recorded audio stays in `Capture/`.
    @Test func aReadFaultOfATakeFileSaysTheAudioIsSafe() throws {
        let error = StudioError.finalize(.readFailed(file: "Capture/take1.anchor", errno: EACCES))
        #expect(L10n.message(for: error) == L10n.errorFinalizeRead.rawValue)
        for (language, text) in [
            (
                "en",
                "The file Capture/take1.anchor of the take can't be read (error 13). The recorded audio stays in Capture/."
            ),
            (
                "es",
                "No se puede leer el archivo Capture/take1.anchor de la toma (error 13). El audio grabado se conserva en Capture/."
            ),
        ] {
            let format = try #require(try stringsTable(language)[L10n.errorFinalizeRead.rawValue])
            #expect(String(format: format, "Capture/take1.anchor", 13) == text, "\(language)")
        }
    }

    @Test func aNewerAnchorNamesTheNewerVersionAndTheWayOut() throws {
        try check(
            .segment(Self.segment, .newerAnchor(version: 2)), .errorSegmentNewerAnchor,
            en:
                "The audio take1-1-1 was made by a newer version of Dirigible. Use Place at Playhead on Selected Track.",
            es: "El audio take1-1-1 se creó con una versión más nueva de Dirigible. "
                + "Usa Colocar en el cursor en la pista seleccionada.")
    }
}
