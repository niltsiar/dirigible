import AppKit
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The pure values of the subtitle and the banners (ui-shell criteria A12, A15).
struct BannerValueTests {
    /// A12: the rate in kHz, "Tracks: N" with no plural form, and the time left in units that
    /// Foundation gives. The test process has no app tables, so the labels come from each table.
    @Test func theSubtitleShowsRateTracksAndTimeLeft() throws {
        for (language, identifier) in [("en", "en_US"), ("es", "es_ES")] {
            let table = try stringsTable(language)
            let locale = Locale(identifier: identifier)
            let text = { (key: L10n) in table[key.rawValue] ?? "" }
            let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .abbreviated).locale(locale)
            let left = Duration.seconds(7_800).formatted(style)
            #expect(
                subtitleText(rate: 48_000, tracks: 3, recordTimeLeft: .seconds(7_800), locale: locale, text: text)
                    == "48 kHz · \(text(.subtitleTracks)) 3 · \(text(.subtitleRecordTime)) \(left)")
            #expect(
                subtitleText(rate: 48_000, tracks: 0, recordTimeLeft: nil, locale: locale, text: text)
                    == "48 kHz · \(text(.subtitleTracks)) 0")
        }
        #expect(
            subtitleText(rate: 44_100, tracks: 1, recordTimeLeft: nil, locale: Locale(identifier: "es_ES")).hasPrefix(
                "44,1 kHz"))
        #expect(try stringsTable("en")[L10n.subtitleTracks.rawValue] == "Tracks:")
    }

    /// A13: before a take under 60 min, during a take under 10 min, and 60 s of hysteresis.
    @Test func theLowRecordTimeRuleHasHysteresis() {
        #expect(!showsLowRecordTime(left: .seconds(3_600), recording: false, shownBefore: false))
        #expect(showsLowRecordTime(left: .seconds(3_599), recording: false, shownBefore: false))
        #expect(showsLowRecordTime(left: .seconds(3_659), recording: false, shownBefore: true))
        #expect(!showsLowRecordTime(left: .seconds(3_660), recording: false, shownBefore: true))
        #expect(!showsLowRecordTime(left: .seconds(600), recording: true, shownBefore: false))
        #expect(showsLowRecordTime(left: .seconds(599), recording: true, shownBefore: false))
        #expect(showsLowRecordTime(left: .seconds(659), recording: true, shownBefore: true))
        #expect(!showsLowRecordTime(left: .seconds(660), recording: true, shownBefore: true))
    }

    /// Code gate 1 item 3: the banner says "Less than N min", so N is over the time left, also at
    /// a whole minute: 30 s gives 1, exactly 5 min gives 6, 59.9 min gives 60.
    @Test func theLowRecordTimeBannerSaysMoreThanTheTimeLeft() {
        #expect(lowRecordTimeMinutes(.seconds(0)) == 1)
        #expect(lowRecordTimeMinutes(.seconds(30)) == 1)
        #expect(lowRecordTimeMinutes(.seconds(299)) == 5)
        #expect(lowRecordTimeMinutes(.seconds(300)) == 6, "exactly 5 min left is not less than 5 min")
        #expect(lowRecordTimeMinutes(.milliseconds(3_594_000)) == 60)
    }

    /// A15, A16: the symbol of each kind, the kind of each banner, its text key, and its
    /// announcement.
    @Test func eachBannerKindHasItsSymbolAndAction() {
        #expect(
            WindowBanner.Kind.allCases.map(\.symbol) == [
                "exclamationmark.triangle.fill", "xmark.octagon.fill", "info.circle", "record.circle",
            ])
        let banners: [(WindowBanner, WindowBanner.Kind, String, NSAccessibilityPriorityLevel?)] = [
            (.playbackStopped(.outputChanged), .warning, L10n.transportStopOutputChanged.text, .high),
            (.missingMedia(["a.wav"]), .error, L10n.mediaMissing.text, .medium),
            (.lowRecordTime(minutes: 5), .warning, L10n.bannerLowRecordTime.text, .high),
        ]
        for (banner, kind, text, announcement) in banners {
            #expect(banner.kind == kind, "\(banner)")
            #expect(banner.text == text, "\(banner)")
            #expect(banner.announcement == announcement, "\(banner)")
        }
        for language in ["en", "es"] {
            let table = (try? stringsTable(language)) ?? [:]
            for key in [L10n.bannerLowRecordTime, .mediaMissing, .transportStopOutputChanged, .transportRecordOver] {
                #expect(table[key.rawValue]?.hasSuffix(".") == true, "\(language) \(key): a fact, then an action")
                #expect((table[key.rawValue]?.split(separator: ".").count ?? 0) >= 2, "\(language) \(key)")
            }
        }
    }
}
