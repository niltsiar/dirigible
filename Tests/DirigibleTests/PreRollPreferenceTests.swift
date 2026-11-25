import Foundation
import Testing

@testable import DirigibleApp

/// Criterion P10 (run 2026-10-28-pre-roll): the pre-roll length is an app preference of 1 to 10 whole
/// seconds, default 3, and Settings shows it as "3 s" next to the label "Pre-roll".
@MainActor struct PreRollPreferenceTests {
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "preroll-\(UUID().uuidString)"))
    }

    private func app() -> AppDelegate { AppDelegate(recordings: nil, defaults: defaults) }

    @Test func noStoredValueReadsThree() {
        #expect(app().preRollSeconds == 3)
    }

    @Test(arguments: [(0, 1), (-4, 1), (1, 1), (4, 4), (10, 10), (60, 10)])
    func aStoredValueClamps(stored: Int, read: Int) {
        defaults.set(stored, forKey: AppDelegate.preRollKey)
        #expect(app().preRollSeconds == read)
    }

    @Test func aStoredValueThatIsNotAWholeNumberReadsThree() {
        defaults.set("long", forKey: AppDelegate.preRollKey)
        #expect(app().preRollSeconds == 3)
        defaults.set(2.5, forKey: AppDelegate.preRollKey)
        #expect(app().preRollSeconds == 3)
    }

    /// A step up from 10 stays 10, and a step down from 1 stays 1: the stepper writes through this setter.
    @Test func stepperStaysInRange() {
        let app = app()
        app.preRollSeconds = 11
        #expect(app.preRollSeconds == 10 && defaults.integer(forKey: AppDelegate.preRollKey) == 10)
        app.preRollSeconds = 0
        #expect(app.preRollSeconds == 1 && defaults.integer(forKey: AppDelegate.preRollKey) == 1)
        app.preRollSeconds = 4
        #expect(self.app().preRollSeconds == 4, "the next launch reads the pick")
    }

    /// The Settings label holds no value: the length with its unit is in the control column.
    @Test func theSettingsLabelHoldsNoValue() throws {
        var withValue: [String] = []
        for language in AppLanguage.allCases.map(\.rawValue) {
            let label = try #require(stringsTable(language)[L10n.settingsPreRoll.rawValue], "\(language)")
            if label.contains("%") || label.contains(":") { withValue.append("\(language): \(label)") }
        }
        #expect(withValue == [])
    }

    @Test func theLengthTextUsesTheNumberFormatOfTheLocale() {
        #expect(preRollLengthText(seconds: 10, locale: Locale(identifier: "en")) == "10 s")
    }
}
