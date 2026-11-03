import SwiftUI

/// The length of the lead-in of Record with Pre-roll (decision 0070): whole seconds, 1 to 10, an
/// app preference. The Settings row writes it, and the key P reads it at the press.
enum PreRollSetting {
    static let range = 1...10
    static let standard = 3

    /// The stored value in `range`. A value that is not a whole number reads as `standard`.
    static func seconds(stored: Any?) -> Int {
        (stored as? Int).map { min(max($0, range.lowerBound), range.upperBound) } ?? standard
    }
}

extension AppDelegate {
    static let preRollKey = "record.preRoll.seconds"

    /// The pre-roll length, in `PreRollSetting.range`. With no defaults (tests), the setter keeps nothing.
    var preRollSeconds: Int {
        get { PreRollSetting.seconds(stored: defaults?.object(forKey: Self.preRollKey)) }
        set { defaults?.set(PreRollSetting.seconds(stored: newValue), forKey: Self.preRollKey) }
    }
}

/// A length in seconds with its unit, "3 s": the number in the format of the locale. The unit is
/// the symbol of the second, the same in each language of the app.
func preRollLengthText(seconds: Int, locale: Locale = .current) -> String {
    "\(seconds.formatted(.number.locale(locale))) s"
}

/// The text of the Settings row, "Pre-roll: 3 s". `text` gives the value of a key.
func preRollRowText(seconds: Int, locale: Locale = .current, text: (L10n) -> String = { $0.text }) -> String {
    String(format: text(.settingsPreRoll), locale: locale, preRollLengthText(seconds: seconds, locale: locale))
}

/// The pre-roll row of Settings: the length with a stepper.
struct PreRollSettingsView: View {
    let app: AppDelegate
    @State private var seconds: Int

    init(app: AppDelegate) {
        self.app = app
        _seconds = State(initialValue: app.preRollSeconds)
    }

    var body: some View {
        Stepper(value: $seconds, in: PreRollSetting.range) {
            Text(verbatim: preRollRowText(seconds: seconds)).monospacedDigit()
        }
        .onChange(of: seconds) { _, new in app.preRollSeconds = new }
    }
}
