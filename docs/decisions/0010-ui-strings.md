# 0010. UI strings: .lproj tables in the app bundle, language through AppleLanguages

- Status: accepted
- Date: 2026-09-24
- Amended: 2026-09-24. The key of a UI string is a dotted name (`menu.record.start`), not the English text. `en.lproj` holds the English values. A typed `L10n` enum in the app target is the only way code names a key, and a test checks both tables against it. `InfoPlist.strings` keeps the Apple rule (see 0014).
- Amended: 2026-10-10, run `2026-10-10-agents-md-restructure`. **Rule** holds the localized UI rule. `AGENTS.md` points here.
- Amended: 2026-10-15, run `2026-10-15-ui-languages`. The UI has seven languages, listed in `AppLanguage`. A run that adds or changes a UI text adds or changes its value in each table, in the same commit. `LocalizationTests` fails a key that a table does not have.
- Amended: 2026-10-29, run `2026-10-29-pt-pt-ui`. The UI has eight languages: European Portuguese (`pt-PT`) joins Brazilian Portuguese (`pt`). A Mac set to `pt-PT`, or to another Portuguese region but Brazil, gets `pt-PT`.
- Amended: 2026-11-24, run `2026-11-24-docs-gate`. Checks names the ellipsis forms of a doc, a menu table, and a `.strings` file.

## Context

R13 asks for a UI in English, Spanish, German, French, Italian, Dutch, Brazilian Portuguese, and European Portuguese. English is the default. The app follows the macOS language, and a preference selects one of these languages or the macOS language. The build is SwiftPM only (0001). A spike in `docs/research/localization.md` found:

- `Bundle.module` crashes inside a `.app` built by the native SwiftPM build system. Its accessor looks next to the executable and at the absolute `.build/` path, not in `Contents/Resources`.
- The native build copies a `.xcstrings` String Catalog without compiling it, so a lookup returns the key.
- `.lproj/Localizable.strings` tables in `Contents/Resources` work with `Text("Record")` and `Bundle.main`.
- `AppleLanguages` in the app's defaults domain selects the language at the next launch. `.environment(\.locale, ...)` changes `Text` lookups but not `String(localized:)` or AppKit text, so the UI could mix languages.

## Decision

- **Rule.** Every user-facing string has a value in each language of `AppLanguage` (`Sources/DirigibleApp/SettingsView.swift`): German (`de`), English (`en`), Spanish (`es`), French (`fr`), Italian (`it`), Dutch (`nl`), Brazilian Portuguese (`pt`), and European Portuguese (`pt-PT`). The raw value of each `AppLanguage` case is its folder name. A run that adds or changes a UI string adds or changes its value in each table, in the same commit. UI strings go in `Support/Resources/<lang>.lproj/Localizable.strings`. Views look them up in `Bundle.main`, never `Bundle.module`. Permission texts go in `Support/Info.plist` and the `InfoPlist.strings` of each folder but `en.lproj`. The CLI and MCP text is English only, because scripts and agents compare it (0011).
- **Files.** `Support/Resources/<lang>.lproj/Localizable.strings` for each language of `AppLanguage`. `Localizable.stringsdict` in each `.lproj` for plurals, only when a text cannot avoid a plural.
- **Translations.** The address of macOS in each language: `de` du, `es` tú, `fr` vous, `it` tu, `nl` je, `pt` você, `pt-PT` no pronoun and no progressive gerund: a verb in the third person (`Pretende ...?`), the possessive `o seu`, and `A <infinitive>` for a progress text (`A exportar`). The terms are those of Logic Pro or GarageBand in that language. The `pt-PT` terms are those of GarageBand and AppKit in `pt_PT` (Logic Pro has no `pt_PT`), with titles in sentence case. The terms that differ from `pt` are in [docs/research/pt-pt-ui.md](../research/pt-pt-ui.md). A text that quotes a menu or button title uses the value of the same table. A value that equals the English value needs its key in the `sameAsEnglish` list of its language in `LocalizationTests`.
- **Keys.** A key is a dotted name in lower case: `<area>.<element>[.<detail>]`, for example `menu.record.start`, `track.route.none`, `take.banner.pending`, `error.studio.locked`. The area is the place in the UI (`menu`, `track`, `take`, `alert`, `error`, `panel`). `en.lproj` holds the English value of every key, so a missing table shows the dotted key, never text in another language. A key names one meaning; two places with the same meaning use one key.
- **Accessor.** `enum L10n: String, CaseIterable` in `Sources/DirigibleApp/L10n.swift`, one case per key, `rawValue` = the key. `L10n.x.key` gives a `LocalizedStringKey` for `Text` and `Button`; `L10n.x.text` gives a `String` from `Bundle.main`; `L10n.x.format(...)` fills the format specifiers. Code never writes a key as a string literal. `L10n.message(for:)` maps each library error case to a key with a switch that has no `default`.
- **Info.plist texts.** `InfoPlist.strings` keeps the Apple keys: the Info.plist key for permission texts (`NSMicrophoneUsageDescription`), and the English value for `CFBundleTypeName` and `UTTypeDescription` ("Dirigible Session"), because macOS looks these up by value.
- **Build.** No change to `Package.swift` or `scripts/bundle.sh`. The existing copy of `Support/Resources` puts the tables in `Contents/Resources`.
- **Views.** `Text(L10n.menuRecordStart.key)`, `Button(L10n.menuRecordStart.key)`, with no `bundle:` argument. A text that a track header row draws uses `Text(verbatim: L10n.x.text)`, `Button(L10n.x.text)`, or `TextField(L10n.x.text, text:)`, so `HeaderStateLineTests` draws it with each table. The help and VoiceOver texts of the row keep `.key`. `Text(verbatim:)` for user data such as track and file names.
- **Library code has no UI text** (0002). The app maps each error case to a table key.
- **Language preference.** A Settings picker writes `AppleLanguages` in the app domain: `[<code>]` for a language of `AppLanguage`, or no key for the macOS language. It lists the endonyms in the order of `AppLanguage`. The picker reads the app's own setting with `persistentDomain(forName:)`. The UI says "Restart Dirigible to apply the language." A pure function maps the choice to the key value, and a unit test covers each case.
- **Checks.**
  - `LocalizationTests` in `make test` (`@testable import DirigibleApp`): the key set of each table equals the set of `L10n` cases, no value is empty, and the format specifiers of each key are the same as in English, in order, or by index when each specifier has one (`%1$@`), and a value ends in the ellipsis character (U+2026) exactly when its English value does. `pt-PT` has no word of a Brazil-only list (`theEuropeanTableHasNoBrazilianWord`). The `.lproj` folders are the languages of `AppLanguage`. `eachInspectorTextFitsItsRoom` checks each inspector text against the room of its group: a new inspector text joins a group.
  - `AppBundleTests`: `CFBundleLocalizations` is the list of `AppLanguage`, each non-English `InfoPlist.strings` has its three texts, and one real key resolves in each language.
  - `ToolbarValueTests`, `ToolbarWindowTests`, and `HeaderStateLineTests` run with each table.
  - **Ellipsis forms.** In a doc, write the ellipsis of a menu item as three dots: **File > Import Session...**. In a menu table of the guide, write the plain name of the item, with no ellipsis. In a `.strings` file, write the ellipsis character (U+2026) or its `\U2026` escape. `scripts/check-docs-drift.py` reads the bold menu paths of the docs and counts three dots and the character as one form.
  - **On-screen languages.** An on-screen check of a new or changed text runs in English and Spanish: launch with `-AppleLanguages "(es)"` and look at the window. The fit tests check each table: the track header (`HeaderStateLineTests`), the toolbar (`ToolbarValueTests` and `ToolbarWindowTests`), the inspector (`LocalizationTests.eachInspectorTextFitsItsRoom`), and Settings (`scripts/settings-fit.swift`; its header names the script that runs it in each language). A new text in a narrow room that no fit test covers also runs on screen in the language with the widest value of that text. A value wider than its inspector room runs the inspector on screen at 240 pt in its language; a pass widens the room.
- **Guide.** The user guide stays English. It names each menu in English and Spanish (`scripts/check-docs.sh`). The other languages get no guide text.
- **Releases.** The tables and their tests are Release 1. The language picker is Release 2. The five languages of the 2026-10-15 amendment are Release 4 (F113). European Portuguese is F169.

## Consequences

- Under `swift run` or `swift test`, `Bundle.main` has no tables, so views show the dotted keys. This is acceptable: `make run` uses the bundle.
- A language change needs a restart.
- Swift 6.4 makes Swift Build the default build system, which compiles String Catalogs. The backlog has an item to check again when the toolchain moves.

## Alternatives considered

- **A String Catalog compiled by `xcstringstool` in `bundle.sh`.** Deferred: the tool interface is not documented. Use it if plurals become common.
- **`Bundle.module` with `defaultLocalization`.** Rejected: it crashes inside the `.app`.
- **`.environment(\.locale, ...)` for a live language switch.** Rejected: AppKit and `String(localized:)` text stay in the old language.
