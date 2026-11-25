import AppKit
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The pure values of the subtitle and the banners (ui-shell criteria A12, A15).
struct BannerValueTests {
    /// A12, F152: the rate in kHz, and the time left rounded down to the minute, in units that
    /// Foundation gives. The test process has no app tables, so the labels come from each table.
    @Test func theSubtitleShowsTheRateAndTheTimeLeft() throws {
        let (en, es) = (try stringsTable("en"), try stringsTable("es"))
        #expect(en[L10n.subtitleRecordTime.rawValue] == "%@ left")
        #expect(es[L10n.subtitleRecordTime.rawValue] == "%@ restantes")
        let (english, spanish) = ({ (key: L10n) in en[key.rawValue] ?? "" }, { (key: L10n) in es[key.rawValue] ?? "" })
        let (enUS, esES) = (Locale(identifier: "en_US"), Locale(identifier: "es_ES"))
        #expect(
            subtitleText(rate: 48_000, recordTimeLeft: .seconds(10_799), locale: enUS, text: english)
                == "48 kHz · 2 hr, 59 min left")
        #expect(
            subtitleText(rate: 48_000, recordTimeLeft: .seconds(10_799), locale: esES, text: spanish)
                == "48 kHz · 2 h y 59 min restantes")
        for (seconds, left) in [(7_199, "1 hr, 59 min"), (3_600, "1 hr"), (59, "0 min")] {
            #expect(
                subtitleText(rate: 48_000, recordTimeLeft: .seconds(seconds), locale: enUS, text: english)
                    == "48 kHz · \(left) left", "\(seconds) s")
        }
        for (table, locale) in [(english, enUS), (spanish, esES)] {
            #expect(subtitleText(rate: 48_000, recordTimeLeft: nil, locale: locale, text: table) == "48 kHz")
        }
        #expect(subtitleText(rate: 44_100, recordTimeLeft: nil, locale: esES).hasPrefix("44,1 kHz"))
    }

    /// C16, F30: the subtitle has the rate and at most one more part: one middle dot at most, and no
    /// colon. The part follows the priority pre-roll, record time left, drag mode. The labels come
    /// from each table, because the test process has none.
    @Test func subtitleHasAtMostOneDotInEachState() throws {
        let lefts: [Duration?] = [nil, .seconds(7_200)]
        for (code, identifier) in [("en", "en_US"), ("es", "es_ES")] {
            let table = try stringsTable(code)
            let text = { (key: L10n) in table[key.rawValue] ?? "" }
            for preRoll in [false, true] {
                for mode in DragMode.allCases {
                    for left in lefts {
                        let result = subtitleText(
                            rate: 48_000, recordTimeLeft: left, preRoll: preRoll, dragMode: mode,
                            locale: Locale(identifier: identifier), text: text)
                        let state = "\(code), pre-roll \(preRoll), \(mode), \(String(describing: left)): \(result)"
                        #expect(result.filter { $0 == "·" }.count <= 1, "\(state)")
                        #expect(!result.contains(":"), "\(state)")
                    }
                }
            }
        }
        let en = try stringsTable("en")
        let english = { (key: L10n) in en[key.rawValue] ?? "" }
        func subtitle(preRoll: Bool = false, mode: DragMode = .overwrite, left: Duration? = nil) -> String {
            subtitleText(
                rate: 48_000, recordTimeLeft: left, preRoll: preRoll, dragMode: mode,
                locale: Locale(identifier: "en_US"), text: english)
        }
        let timeLeft = String(format: english(.subtitleRecordTime), "2 hr")
        let cue = String(format: english(.timelineDragModeCue), english(.menuEditDragModeShuffle))
        let twoHours = Duration.seconds(7_200)
        #expect(subtitle() == "48 kHz")
        #expect(subtitle(preRoll: true, mode: .shuffle, left: twoHours) == "48 kHz · \(english(.subtitlePreRoll))")
        #expect(subtitle(mode: .shuffle, left: twoHours) == "48 kHz · \(timeLeft)")
        #expect(subtitle(mode: .shuffle) == "48 kHz · \(cue)")
        for code in ["de", "en", "es", "fr", "it", "nl", "pt", "pt-PT"] {
            let table = try stringsTable(code)
            for key in [L10n.subtitleRecordTime, .timelineDragModeCue] {
                let value = table[key.rawValue] ?? ""
                #expect(!value.contains(":"), "\(code) \(key.rawValue): \(value)")
            }
        }
        #expect(L10n(rawValue: "subtitle.tracks") == nil, "the track count is not in the subtitle")
    }

    /// F152: before a take under 3 h with a band of 300 s, during a take under 10 min with a band
    /// of 60 s. A banner that showed before a take hides at a take start with more than 10 min.
    @Test func theLowRecordTimeRuleHasHysteresis() {
        #expect(showsLowRecordTime(left: .seconds(10_799), recording: false, shownBefore: false))
        #expect(!showsLowRecordTime(left: .seconds(10_800), recording: false, shownBefore: false))
        #expect(!showsLowRecordTime(left: .seconds(10_801), recording: false, shownBefore: false))
        #expect(showsLowRecordTime(left: .seconds(11_099), recording: false, shownBefore: true))
        #expect(!showsLowRecordTime(left: .seconds(11_100), recording: false, shownBefore: true))
        #expect(!showsLowRecordTime(left: .seconds(600), recording: true, shownBefore: false))
        #expect(showsLowRecordTime(left: .seconds(599), recording: true, shownBefore: false))
        #expect(showsLowRecordTime(left: .seconds(659), recording: true, shownBefore: true))
        #expect(!showsLowRecordTime(left: .seconds(660), recording: true, shownBefore: true))
        #expect(
            !showsLowRecordTime(left: .seconds(3_000), recording: true, shownBefore: true), "the take start hides it")
    }

    /// Code gate 1 item 3, F152: the banner says "Less than N", so N is over the time left, also
    /// at a whole minute: 30 s gives 1 min, exactly 5 min gives 6 min, 2 h gives 2 hr, 1 min.
    @Test func theLowRecordTimeBannerSaysMoreThanTheTimeLeft() throws {
        #expect(lowRecordTimeMinutes(.seconds(0)) == 1)
        #expect(lowRecordTimeMinutes(.seconds(30)) == 1)
        #expect(lowRecordTimeMinutes(.seconds(299)) == 5)
        #expect(lowRecordTimeMinutes(.seconds(300)) == 6, "exactly 5 min left is not less than 5 min")
        #expect(lowRecordTimeMinutes(.milliseconds(3_594_000)) == 60)
        #expect(lowRecordTimeMinutes(.seconds(7_200)) == 121)
        #expect(lowRecordTimeMinutes(.seconds(10_799)) == 180)
        let (en, es) = (try stringsTable("en"), try stringsTable("es"))
        let (english, spanish) = ({ (key: L10n) in en[key.rawValue] ?? "" }, { (key: L10n) in es[key.rawValue] ?? "" })
        let enUS = Locale(identifier: "en_US")
        let action = " of record time left on this disk. Free up disk space before you record."
        #expect(lowRecordTimeText(minutes: 121, locale: enUS, text: english) == "Less than 2 hr, 1 min" + action)
        #expect(lowRecordTimeText(minutes: 180, locale: enUS, text: english) == "Less than 3 hr" + action)
        #expect(lowRecordTimeText(minutes: 1, locale: enUS, text: english) == "Less than 1 min" + action)
        #expect(
            lowRecordTimeText(minutes: 150, locale: Locale(identifier: "es_ES"), text: spanish)
                == "Quedan menos de 2 h y 30 min de grabación en este disco. Libera espacio antes de grabar.")
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
            (.lowRecordTime(minutes: 5), .warning, L10n.bannerLowRecordTimeLeft.text, .high),
            (
                .levelReport(LevelReport(changed: 0, atLimit: 0, unmeasured: 0), press: 1), .info,
                L10n.bannerLevelNone.text + " " + L10n.bannerLevelVolume.text, .medium
            ),
            (
                .levelReport(LevelReport(changed: 1, atLimit: 1, unmeasured: 0), press: 1), .warning,
                L10n.bannerLevelLimitOne.text, .medium
            ),
            (
                .levelReport(LevelReport(changed: 1, atLimit: 0, unmeasured: 1), press: 1), .warning,
                L10n.bannerLevelUnmeasuredOne.text, .medium
            ),
            (
                .leveledOverTime(RideResult(leveled: 2, unmeasured: 1, gain: 4), press: 1), .warning,
                L10n.rideUnmeasuredOne.text, .medium
            ),
            (
                .soundRepaired(RepairResult(clips: 2, declip: true, others: false, repaired: 2, drop: 4), press: 1),
                .warning, L10n.repairDropMany.format(4), .medium
            ),
            (
                .soundRepaired(RepairResult(clips: 2, declip: true, others: false, repaired: 0, drop: 0), press: 1),
                .info, L10n.repairNone.text, .medium
            ),
        ]
        for (banner, kind, text, announcement) in banners {
            #expect(banner.kind == kind, "\(banner)")
            #expect(banner.text == text, "\(banner)")
            #expect(banner.announcement == announcement, "\(banner)")
        }
        for language in AppLanguage.allCases.map(\.rawValue) {
            let table = (try? stringsTable(language)) ?? [:]
            for key in [L10n.bannerLowRecordTimeLeft, .mediaMissing, .transportStopOutputChanged] {
                #expect(table[key.rawValue]?.hasSuffix(".") == true, "\(language) \(key): a fact, then an action")
                #expect((table[key.rawValue]?.split(separator: ".").count ?? 0) >= 2, "\(language) \(key)")
            }
        }
    }
}
