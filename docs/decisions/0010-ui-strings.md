# 0010. UI strings: .lproj tables in the app bundle, language through AppleLanguages

- Status: accepted
- Date: 2026-09-24
- Amended: 2026-09-24. The key of a UI string is a dotted name (`menu.record.start`), not the English text. `en.lproj` holds the English values. A typed `L10n` enum in the app target is the only way code names a key, and a test checks both tables against it. `InfoPlist.strings` keeps the Apple rule (see 0014).

## Context

R13 asks for an English and a Spanish UI. English is the default. The app follows the macOS language, and a preference selects English, Spanish, or the macOS language. The build is SwiftPM only (0001). A spike in `docs/research/localization.md` found:

- `Bundle.module` crashes inside a `.app` built by the native SwiftPM build system. Its accessor looks next to the executable and at the absolute `.build/` path, not in `Contents/Resources`.
- The native build copies a `.xcstrings` String Catalog without compiling it, so a lookup returns the key.
- `.lproj/Localizable.strings` tables in `Contents/Resources` work with `Text("Record")` and `Bundle.main`.
- `AppleLanguages` in the app's defaults domain selects the language at the next launch. `.environment(\.locale, ...)` changes `Text` lookups but not `String(localized:)` or AppKit text, so the UI could mix languages.

## Decision

- **Files.** `Support/Resources/en.lproj/Localizable.strings` and `Support/Resources/es.lproj/Localizable.strings`. `Localizable.stringsdict` in each `.lproj` for plurals, only when a text cannot avoid a plural.
- **Keys.** A key is a dotted name in lower case: `<area>.<element>[.<detail>]`, for example `menu.record.start`, `track.route.none`, `take.banner.pending`, `error.studio.locked`. The area is the place in the UI (`menu`, `track`, `take`, `alert`, `error`, `panel`). `en.lproj` holds the English value of every key, so a missing table shows the dotted key, never text in another language. A key names one meaning; two places with the same meaning use one key.
- **Accessor.** `enum L10n: String, CaseIterable` in `Sources/DirigibleApp/L10n.swift`, one case per key, `rawValue` = the key. `L10n.x.key` gives a `LocalizedStringKey` for `Text` and `Button`; `L10n.x.text` gives a `String` from `Bundle.main`; `L10n.x.format(...)` fills the format specifiers. Code never writes a key as a string literal. `L10n.message(for:)` maps each library error case to a key with a switch that has no `default`.
- **Info.plist texts.** `InfoPlist.strings` keeps the Apple keys: the Info.plist key for permission texts (`NSMicrophoneUsageDescription`), and the English value for `CFBundleTypeName` and `UTTypeDescription` ("Dirigible Session"), because macOS looks these up by value.
- **Build.** No change to `Package.swift` or `scripts/bundle.sh`. The existing copy of `Support/Resources` puts the tables in `Contents/Resources`.
- **Views.** `Text(L10n.menuRecordStart.key)`, `Button(L10n.menuRecordStart.key)`, with no `bundle:` argument. `Text(verbatim:)` for user data such as track and file names.
- **Library code has no UI text** (0002). The app maps each error case to a table key.
- **Language preference.** A Settings picker with three values writes `AppleLanguages` in the app domain: `["en"]`, `["es"]`, or no key for the macOS language. The picker reads the app's own setting with `persistentDomain(forName:)`. The UI says "Restart Dirigible to apply the language." A pure function maps the choice to the key value, and a unit test covers the three cases.
- **Checks.**
  - `LocalizationTests` in `make test` (`@testable import DirigibleApp`): the key set of each table equals the set of `L10n` cases, no value is empty, and the format specifiers of each key are the same in English and Spanish.
  - `AppBundleTests`: the bundle lists `en` and `es`, and one real key resolves to Spanish from `es.lproj`.
  - A manual check in the run ledger: launch with `-AppleLanguages "(es)"` and look at the window.
- **Releases.** The tables and their tests are Release 1. The language picker is Release 2.

## Consequences

- Under `swift run` or `swift test`, `Bundle.main` has no tables, so views show the dotted keys. This is acceptable: `make run` uses the bundle.
- A language change needs a restart.
- Swift 6.4 makes Swift Build the default build system, which compiles String Catalogs. The backlog has an item to check again when the toolchain moves.

## Alternatives considered

- **A String Catalog compiled by `xcstringstool` in `bundle.sh`.** Deferred: the tool interface is not documented. Use it if plurals become common.
- **`Bundle.module` with `defaultLocalization`.** Rejected: it crashes inside the `.app`.
- **`.environment(\.locale, ...)` for a live language switch.** Rejected: AppKit and `String(localized:)` text stay in the old language.
