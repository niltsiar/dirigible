import DirigibleCore
import DirigibleMCP
import Foundation
import Testing

@testable import DirigibleApp

/// The consent message of an agent record request.
extension ConsentTests {
    /// ui-audit A4: the length of the take and the time to answer are both in words in each language,
    /// with no "s" abbreviation for one of them.
    @Test func theConsentMessageGivesBothTimesInWords() throws {
        for (language, locale, expected) in [
            ("en", "en_US", "The take records 30 seconds on Host from 0:00. Answer within 20 seconds."),
            ("es", "es_ES", "La toma graba 30 segundos en Host desde 0:00. Responde en 20 segundos."),
        ] {
            let format = try #require(try stringsTable(language)[L10n.consentMessage.rawValue])
            let text = consentMessageText(
                seconds: 30, names: "Host", start: "0:00", limit: RecordRequest.answerLimit,
                locale: Locale(identifier: locale), format: format)
            #expect(text == expected)
        }
        for language in AppLanguage.allCases.map(\.rawValue) {
            let format = try #require(try stringsTable(language)[L10n.consentMessage.rawValue])
            #expect(format.contains("%4$@") && !format.contains("%4$lld"), "\(language): \(format)")
        }
    }
}
