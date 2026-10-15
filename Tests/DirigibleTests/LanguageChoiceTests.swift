import Foundation
import Testing

@testable import DirigibleApp

/// The language preference (R13, decision 0010): the value of each choice, the read of the app
/// domain, and the write.
struct LanguageChoiceTests {
    /// C1: each language stores its code; System Language stores no key.
    @Test func valueOfEachChoice() {
        #expect(LanguageChoice.system.appleLanguages == nil)
        #expect(LanguageChoice.language(.german).appleLanguages == ["de"])
        #expect(LanguageChoice.language(.english).appleLanguages == ["en"])
        #expect(LanguageChoice.language(.spanish).appleLanguages == ["es"])
    }

    /// C8: the pop-up lists the endonyms in the order of `AppLanguage`.
    @Test func endonymOfEachLanguage() {
        #expect(AppLanguage.allCases.map(\.endonym) == ["Deutsch", "English", "Español"])
    }

    /// C3: a stored list shows the language of the next launch, never System Language.
    @Test(arguments: [
        (["de-AT"], LanguageChoice.language(.german)), (["es"], .language(.spanish)),
        (["es-ES"], .language(.spanish)), (["es-MX"], .language(.spanish)), (["ja", "es"], .language(.spanish)),
        (["fr", "es"], .language(.spanish)), (["en"], .language(.english)), (["en-GB"], .language(.english)),
        (["ja"], .language(.english)), (["fr"], .language(.english)),
    ])
    func readMapsTheStoredValue(stored: [String], choice: LanguageChoice) {
        #expect(LanguageChoice(stored: stored) == choice)
    }

    /// C3: no key in the app domain reads as System Language, although the search list of
    /// `defaults` has a language list. The test adds that list, so it does not depend on the global
    /// domain of the account.
    @Test func noKeyReadsAsSystem() throws {
        let domain = "DirigibleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        // An added suite comes before the global domain in the search list of this instance only.
        // `register(defaults:)` is no control: it is for the whole process, and the global domain wins.
        let list = domain + "-list"
        let listDefaults = try #require(UserDefaults(suiteName: list))
        defer { listDefaults.removePersistentDomain(forName: list) }
        listDefaults.set(["es"], forKey: LanguageChoice.key)
        defaults.addSuite(named: list)
        #expect(defaults.stringArray(forKey: LanguageChoice.key) == ["es"], "the search list has a list")
        #expect(LanguageChoice(defaults, domain: domain) == .system)
    }

    /// C2: each language sets the key in the app domain; System Language removes it.
    @Test func writeSetsAndRemovesTheKey() throws {
        let domain = "DirigibleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let stored = { defaults.persistentDomain(forName: domain)?[LanguageChoice.key] as? [String] }
        LanguageChoice.language(.english).write(to: defaults)
        #expect(stored() == ["en"])
        LanguageChoice.language(.spanish).write(to: defaults)
        #expect(stored() == ["es"])
        #expect(LanguageChoice(defaults, domain: domain) == .language(.spanish))
        LanguageChoice.system.write(to: defaults)
        #expect(stored() == nil)
        #expect(LanguageChoice(defaults, domain: domain) == .system)
    }

    /// C13: a stored list whose first language Dirigible does not have reads as a language, so a
    /// System Language pick is a change and removes the key.
    @Test func systemPickAfterAStoredListRemovesTheKey() throws {
        let domain = "DirigibleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(["ja", "es"], forKey: LanguageChoice.key)
        #expect(LanguageChoice(defaults, domain: domain) == .language(.spanish))
        LanguageChoice.system.write(to: defaults)
        #expect(defaults.persistentDomain(forName: domain)?[LanguageChoice.key] == nil)
    }

    /// With no domain, the view neither reads nor writes: a write through `defaults` alone would
    /// store a choice that the pop-up then does not show (code gate item 1).
    @MainActor @Test func noDomainNeitherReadsNorWrites() throws {
        let domain = "DirigibleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(SettingsView(defaults: defaults, domain: nil).defaults == nil)
        #expect(SettingsView(defaults: defaults, domain: domain).defaults === defaults)
    }
}
