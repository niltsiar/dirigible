import Foundation
import SwiftUI

/// A language of the UI (R13, decision 0010). The one list of the `.lproj` folders, of
/// `CFBundleLocalizations`, of the Settings pop-up, and of the text-rule tests. The order is the
/// order of the pop-up.
enum AppLanguage: String, CaseIterable {
    case german = "de"
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case italian = "it"

    /// The name of the language in that language, so a user who cannot read the current UI
    /// language still finds theirs.
    var endonym: String {
        switch self {
        case .german: "Deutsch"
        case .english: "English"
        case .spanish: "Español"
        case .french: "Français"
        case .italian: "Italiano"
        }
    }
}

/// The language of the app (R13, decision 0010). Each language stores its code in the app
/// domain; System Language stores no key, so the app follows macOS. The change applies at the
/// next launch.
enum LanguageChoice: Hashable {
    case system
    case language(AppLanguage)

    static let key = "AppleLanguages"

    var appleLanguages: [String]? {
        switch self {
        case .system: nil
        case .language(let language): [language.rawValue]
        }
    }

    /// Only no key is System Language. A stored list shows the language that the runtime picks
    /// from it at launch, so a System Language pick always removes the key.
    init(stored: [String]?) {
        guard let stored else {
            self = .system
            return
        }
        let code = Bundle.preferredLocalizations(
            from: AppLanguage.allCases.map(\.rawValue), forPreferences: stored
        ).first
        self = .language(code.flatMap(AppLanguage.init(rawValue:)) ?? .english)
    }

    /// The app domain only: `defaults` alone also returns the global language list.
    init(_ defaults: UserDefaults, domain: String) {
        self.init(stored: defaults.persistentDomain(forName: domain)?[Self.key] as? [String])
    }

    func write(to defaults: UserDefaults) {
        defaults.set(appleLanguages, forKey: Self.key)
    }
}

/// Dirigible > Settings: one pane with the language pop-up (run 15 UI panel) and the agent
/// switch (decision 0046).
struct SettingsView: View {
    /// Nil: no read and no write (tests, or no bundle ID under `swift run`). `defaults` and
    /// `domain` of `init` name the same domain.
    let defaults: UserDefaults?
    /// Nil: no agent part (tests).
    let app: AppDelegate?
    /// The first value comes from `init`, not from `onAppear`: a set there runs `onChange`, which
    /// writes over a stored list such as `["ja", "es"]`.
    @State private var choice: LanguageChoice

    init(defaults: UserDefaults?, domain: String?, app: AppDelegate? = nil) {
        self.app = app
        // One guard for the read and the write, so the pop-up always shows what a pick stores.
        if let defaults, let domain {
            self.defaults = defaults
            _choice = State(initialValue: LanguageChoice(defaults, domain: domain))
        } else {
            self.defaults = nil
            _choice = State(initialValue: .system)
        }
    }

    var body: some View {
        Form {
            Picker(L10n.settingsLanguage.key, selection: $choice) {
                Text(L10n.settingsLanguageSystem.key).tag(LanguageChoice.system)
                Divider()
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(verbatim: language.endonym).tag(LanguageChoice.language(language))
                }
            }
            Text(L10n.settingsLanguageRestart.key).settingsHelp()
            if let app {
                Divider()
                AgentSettingsView(app: app)
            }
        }
        // No fixed width: the window takes the width of the longest label in the app language.
        // fixedSize: the window takes the ideal size, not the largest size of the form.
        .padding(20)
        .fixedSize()
        .onChange(of: choice) { _, new in
            if let defaults { new.write(to: defaults) }
        }
    }
}

extension Text {
    /// A help line of Settings. It wraps at 260 pt, so that the window does not grow to the width
    /// of a long line. A fixed width, not a maximum: the ideal height of the window then counts
    /// the wrapped lines.
    func settingsHelp() -> some View {
        font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(width: 260, alignment: .leading)
    }
}
