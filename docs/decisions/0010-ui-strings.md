# 0010. UI strings: .lproj tables in the app bundle, language through AppleLanguages

- Status: accepted
- Date: 2026-09-24

## Context

R13 asks for an English and a Spanish UI. English is the default. The app follows the macOS language, and a preference selects English, Spanish, or the macOS language. The build is SwiftPM only (0001). A spike in `docs/research/localization.md` found:

- `Bundle.module` crashes inside a `.app` built by the native SwiftPM build system. Its accessor looks next to the executable and at the absolute `.build/` path, not in `Contents/Resources`.
- The native build copies a `.xcstrings` String Catalog without compiling it, so a lookup returns the key.
- `.lproj/Localizable.strings` tables in `Contents/Resources` work with `Text("Record")` and `Bundle.main`.
- `AppleLanguages` in the app's defaults domain selects the language at the next launch. `.environment(\.locale, ...)` changes `Text` lookups but not `String(localized:)` or AppKit text, so the UI could mix languages.

## Decision

- **Files.** `Support/Resources/en.lproj/Localizable.strings` and `Support/Resources/es.lproj/Localizable.strings`. The key is the English text. `Localizable.stringsdict` in each `.lproj` for plurals.
- **Build.** No change to `Package.swift` or `scripts/bundle.sh`. The existing copy of `Support/Resources` puts the tables in `Contents/Resources`.
- **Views.** `Text("Record")`, `Button("Record")`, `Label("Record", systemImage:)`, with no `bundle:` argument. `Text(verbatim:)` for user data such as track and file names.
- **Library code has no UI text** (0002). The app maps each error case to a table key.
- **Language preference.** A Settings picker with three values writes `AppleLanguages` in the app domain: `["en"]`, `["es"]`, or no key for the macOS language. The picker reads the app's own setting with `persistentDomain(forName:)`. The UI says "Restart Dirigible to apply the language." A pure function maps the choice to the key value, and a unit test covers the three cases.
- **Checks.**
  - `LocalizationTests` in `make test`: the English and Spanish tables have the same keys, and no value is empty.
  - `AppBundleTests`: the bundle lists `en` and `es`, and one real key resolves to Spanish from `es.lproj`.
  - A manual check in the run ledger: launch with `-AppleLanguages "(es)"` and look at the window.
- **Releases.** The tables and their tests are Release 1. The language picker is Release 2.

## Consequences

- Under `swift run` or `swift test`, `Bundle.main` has no tables, so views show the English keys. This is acceptable.
- A language change needs a restart.
- Swift 6.4 makes Swift Build the default build system, which compiles String Catalogs. The backlog has an item to check again when the toolchain moves.

## Alternatives considered

- **A String Catalog compiled by `xcstringstool` in `bundle.sh`.** Deferred: the tool interface is not documented. Use it if plurals become common.
- **`Bundle.module` with `defaultLocalization`.** Rejected: it crashes inside the `.app`.
- **`.environment(\.locale, ...)` for a live language switch.** Rejected: AppKit and `String(localized:)` text stay in the old language.
