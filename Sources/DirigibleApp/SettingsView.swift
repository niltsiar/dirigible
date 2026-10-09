import Foundation
import SwiftUI

/// The language of the app (R13, decision 0010). English and Spanish store one language in the app
/// domain; System Language stores no key, so the app follows macOS. The change applies at the next
/// launch.
enum LanguageChoice: Hashable {
    case system, english, spanish

    static let key = "AppleLanguages"

    var appleLanguages: [String]? {
        switch self {
        case .system: nil
        case .english: ["en"]
        case .spanish: ["es"]
        }
    }

    /// Only no key is System Language. A stored list shows the language that the runtime picks
    /// from it at launch, so a System Language pick always removes the key.
    init(stored: [String]?) {
        guard let stored else {
            self = .system
            return
        }
        self =
            Bundle.preferredLocalizations(from: ["en", "es"], forPreferences: stored).first == "es"
            ? .spanish : .english
    }

    /// The app domain only: `defaults` alone also returns the global language list.
    init(_ defaults: UserDefaults, domain: String) {
        self.init(stored: defaults.persistentDomain(forName: domain)?[Self.key] as? [String])
    }

    func write(to defaults: UserDefaults) {
        defaults.set(appleLanguages, forKey: Self.key)
    }
}

/// Dirigible > Settings: one pane with the language pop-up (run 15 UI panel).
struct SettingsView: View {
    /// Nil: no read and no write (tests). `defaults` and `domain` of `init` name the same domain.
    let defaults: UserDefaults?
    /// The first value comes from `init`, not from `onAppear`: a set there runs `onChange`, which
    /// writes over a stored list such as `["fr", "es"]`.
    @State private var choice: LanguageChoice

    init(defaults: UserDefaults?, domain: String?) {
        self.defaults = defaults
        if let defaults, let domain {
            _choice = State(initialValue: LanguageChoice(defaults, domain: domain))
        } else {
            _choice = State(initialValue: .system)
        }
    }

    var body: some View {
        Form {
            Picker(L10n.settingsLanguage.key, selection: $choice) {
                Text(L10n.settingsLanguageSystem.key).tag(LanguageChoice.system)
                Divider()
                // Endonyms: a user who cannot read the current language still finds the own one.
                Text(verbatim: "English").tag(LanguageChoice.english)
                Text(verbatim: "Español").tag(LanguageChoice.spanish)
            }
            Text(L10n.settingsLanguageRestart.key).font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: choice) { _, new in
            if let defaults { new.write(to: defaults) }
        }
    }
}
