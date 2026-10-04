import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp

/// Both string tables hold every `L10n` key and nothing else, with a value and the same format
/// specifiers (decision 0010). `AppBundleTests` checks the tables in the built bundle.
struct LocalizationTests {
    @Test func bothTablesMatchTheKeys() throws {
        let problems = tableProblems(
            en: try stringsTable("en"), es: try stringsTable("es"), keys: L10n.allCases.map(\.rawValue))
        #expect(problems == [])
    }

    @Test func checkerFindsAMissingKeyAndAnOtherSpecifier() {
        let problems = tableProblems(
            en: ["a.one": "One %@", "a.two": "Two"], es: ["a.one": "Uno %lld", "a.extra": "Más"],
            keys: ["a.one", "a.two"])
        #expect(
            problems == [
                "es: no value for a.two", "es: key a.extra is not in L10n",
                "a.one: specifiers [\"%@\"] in en, [\"%lld\"] in es",
            ])
    }

    /// Crossfades F2b: the window never makes a crossfade error, so each one shows the text of a
    /// refused change (code gate 1).
    @Test func eachCrossfadeErrorShowsTheRefusedChangeText() {
        for error in [
            SessionError.crossfadeOutsideFile("B", needed: 480), .crossfadeWithoutJoin("A"),
            .crossfadeAtSeamlessJoin("A"),
            .fadeAtCrossfade("A"),
        ] {
            #expect(L10n.message(for: .session(error)) == L10n.errorSessionOther.rawValue, "\(error)")
        }
    }

    @Test func checkerFindsAnEmptyValue() {
        #expect(tableProblems(en: ["a": "A"], es: ["a": ""], keys: ["a"]) == ["es: no value for a"])
    }
}

/// The `Localizable.strings` table of `language` in `Support/Resources`.
func stringsTable(_ language: String) throws -> [String: String] {
    let url = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../Support/Resources/\(language).lproj/Localizable.strings").standardized
    let data = try Data(contentsOf: url)
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
}

/// The problems of two tables against the keys, in a stable order: per table, the missing or
/// empty values, then the extra keys; then the keys whose specifiers differ.
func tableProblems(en: [String: String], es: [String: String], keys: [String]) -> [String] {
    var problems: [String] = []
    for (language, table) in [("en", en), ("es", es)] {
        for key in keys where table[key]?.isEmpty != false { problems.append("\(language): no value for \(key)") }
        for key in table.keys.sorted() where !keys.contains(key) {
            problems.append("\(language): key \(key) is not in L10n")
        }
    }
    for key in keys {
        guard let english = en[key], let spanish = es[key] else { continue }
        let (a, b) = (specifiers(english), specifiers(spanish))
        if a != b { problems.append("\(key): specifiers \(a) in en, \(b) in es") }
    }
    return problems
}

/// The format specifiers of a value, sorted, so a positional reorder in a language is allowed.
private func specifiers(_ value: String) -> [String] {
    value.matches(of: /%(\d+\$)?(ll|l)?[@dfs]/).map { String($0.output.0) }.sorted()
}
