import Foundation
import Testing

@testable import DirigibleApp

/// The language preference (R13, decision 0010): the value of each choice, the read of the app
/// domain, and the write.
struct LanguageChoiceTests {
    /// C1: English and Spanish store one language; System Language stores no key.
    @Test func valueOfEachChoice() {
        #expect(LanguageChoice.system.appleLanguages == nil)
        #expect(LanguageChoice.english.appleLanguages == ["en"])
        #expect(LanguageChoice.spanish.appleLanguages == ["es"])
    }

    /// C3: a stored list shows the language of the next launch, never System Language.
    @Test(arguments: [
        (["es"], LanguageChoice.spanish), (["es-ES"], .spanish), (["es-MX"], .spanish), (["fr", "es"], .spanish),
        (["en"], .english), (["en-GB"], .english), (["fr"], .english),
    ])
    func readMapsTheStoredValue(stored: [String], choice: LanguageChoice) {
        #expect(LanguageChoice(stored: stored) == choice)
    }

    /// C3: no key in the app domain reads as System Language, although the global domain has a
    /// language list.
    @Test func noKeyReadsAsSystem() throws {
        let domain = "DirigibleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(defaults.stringArray(forKey: LanguageChoice.key) != nil, "the global domain has a list")
        #expect(LanguageChoice(defaults, domain: domain) == .system)
    }

    /// C2: English and Spanish set the key in the app domain; System Language removes it.
    @Test func writeSetsAndRemovesTheKey() throws {
        let domain = "DirigibleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let stored = { defaults.persistentDomain(forName: domain)?[LanguageChoice.key] as? [String] }
        LanguageChoice.english.write(to: defaults)
        #expect(stored() == ["en"])
        LanguageChoice.spanish.write(to: defaults)
        #expect(stored() == ["es"])
        #expect(LanguageChoice(defaults, domain: domain) == .spanish)
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
        defaults.set(["fr", "es"], forKey: LanguageChoice.key)
        #expect(LanguageChoice(defaults, domain: domain) == .spanish)
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
