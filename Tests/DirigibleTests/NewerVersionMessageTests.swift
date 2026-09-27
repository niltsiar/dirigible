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
}
