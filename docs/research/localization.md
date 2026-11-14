# Localized UI strings with SwiftPM (R13)

Date: 2026-09-23

This note answers the R13 open question in `docs/requirements/brief.md`. How does SwiftPM ship the UI strings in the app bundle, and how does the language preference override the macOS language?

## Facts

### Test environment

- Toolchain: Xcode 26, Swift 6.2.4, native SwiftPM build system. Host: macOS 15.7.9.
- Spike: a copy of the repo in a temporary folder, `l10n-spike`. A probe in `DirigibleApp.init` prints lookups and exits.
- The probe reads SwiftUI `Text` output with `ImageRenderer`. It compares the pixels to `Text(verbatim:)` of each candidate string.
- The spike did not run on macOS 14. Results for macOS 14 are "(unconfirmed)" where the behavior can differ.

### SwiftPM resources (native build system, Swift 6.2)

1. With `defaultLocalization: "en"` and `.process("Resources")`, `swift build` makes `Dirigible_Dirigible.bundle` next to the executable in `.build/<triple>/<config>/`. Its `Info.plist` has only `CFBundleDevelopmentRegion = en`. (Spike.)
2. SwiftPM copies a `Localizable.xcstrings` file into the bundle without change. It does not compile it to `.strings`. A lookup of a key returns the fallback value. (Spike: `localizedString(forKey: "Record")` returned `MISSING`; `bundle.localizations` was `["en"]`.) The community reports the same gap for `swift build`. [4]
3. `en.lproj/Localizable.strings` and `es.lproj/Localizable.strings` in `Resources/` work. SwiftPM copies the `.lproj` folders into the bundle. Lookup gives `Record` and `Grabar`. (Spike.)
4. The generated `resource_bundle_accessor.swift` looks in two places only:
   `Bundle.main.bundleURL/Dirigible_Dirigible.bundle`, then the absolute build path in `.build/`. (Spike, file in `.build/.../DerivedSources/`.)
5. In a `.app`, `Bundle.main.bundleURL` is `Dirigible.app/`. A bundle in `Contents/Resources/` is not found. On the development Mac the accessor silently uses the `.build/` copy. On any other Mac it crashes. (Spike: with the `.build/` copy hidden, the app stopped with `Fatal error: could not load resource bundle: from .../A.app/Dirigible_Dirigible.bundle or .../.build/...`.)
6. A resource bundle at the `.app` root does not sign. (Spike: `codesign` printed `unsealed contents present in the bundle root`.)
7. The Swift Build system (`swift build --build-system swiftbuild`) is a preview in Swift 6.2. It compiles `Localizable.xcstrings` to `en.lproj` and `es.lproj`. Its accessor also looks in `Bundle.main.resourceURL`, so `Contents/Resources/` works. (Spike.) Swift 6.4 (released 2026-09-15) makes Swift Build the default. [5], [6]

### Command-line String Catalog compiler

8. `xcrun xcstringstool compile Localizable.xcstrings --output-directory <dir>` writes `en.lproj/Localizable.strings` and `es.lproj/Localizable.strings`. It writes `.stringsdict` files for plural variants. (Spike; `xcstringstool help compile`.) Apple does not document this tool on the web (unconfirmed that its interface is stable).

### How SwiftUI finds a string

9. `Text("key")` with a literal makes a `LocalizedStringKey`. With `bundle: nil`, it uses the main bundle and the `Localizable` table. [1], [2]
10. Strings in `Contents/Resources/<lang>.lproj/Localizable.strings` of the app work with plain `Text("Record")`. No `bundle:` argument is necessary. (Spike, layout B.) Views in any module, library targets included, use `Bundle.main` by default.
11. An interpolated literal uses a format key. `Text("\(3) tracks")` looks up `"%lld tracks"` and shows `3 pistas`. (Spike.)

### Language selection

12. `-AppleLanguages "(es)"` at launch gives Spanish for `Text`, `String(localized:)`, and `LocalizedStringResource`. (Spike.)
13. `defaults write <bundle id> AppleLanguages -array es`, then a launch, gives Spanish. `defaults delete` returns to the macOS list. (Spike.)
14. `UserDefaults.standard.set(["es"], forKey: "AppleLanguages")` in a running app does not change lookups in that process. (Spike: `Record` before and after.) The change applies at the next launch.
15. `UserDefaults.standard` returns the global language list when the app domain has no `AppleLanguages` key. (Spike: `["en-ES", "es-ES"]`.) Use `UserDefaults.standard.persistentDomain(forName:)` to read the app override only.
16. Fallback works as expected: `es-MX` gives Spanish, `(fr, es)` gives Spanish, `(fr)` gives English. (Spike.) English comes from `CFBundleDevelopmentRegion = en`.
17. `.environment(\.locale, Locale(identifier: "es"))` changes the `Text` lookup live. (Spike on macOS 15.7: `Text("Record")` showed `Grabar`.) It does not change `String(localized:)`. `String(localized:locale:)` uses the locale for formatting only (spike: `Record`). The same `Text` behavior on macOS 14 is unconfirmed.
18. macOS has a per-app language list in System Settings > General > Language & Region > Applications. [7] It probably writes `AppleLanguages` in the app domain (unconfirmed).

## Options

### Where the strings live

| Option | Build change | View code | Result |
|---|---|---|---|
| A. `Support/Resources/{en,es}.lproj/Localizable.strings` | None. `bundle.sh` already copies `Support/Resources/.` | `Text("Record")` | Works (spike, layout B). |
| B. `Support/Localizable.xcstrings`, compiled by `xcstringstool` in `bundle.sh` | One line in `bundle.sh` | `Text("Record")` | Works (spike: layout B used `xcstringstool` output). Plurals in one file. Tool not documented. |
| C. SwiftPM resources, `defaultLocalization`, `Bundle.module` | `Package.swift` and `bundle.sh` | `Text("Record", bundle: .module)` everywhere | Fails in the `.app` (facts 5, 6). `.xcstrings` not compiled (fact 2). Reject. |
| D. Swift Build (`--build-system swiftbuild`) with `.xcstrings` | `Makefile`, `bundle.sh`, `Package.swift` | `Text("Record", bundle: .module)` | Works in the spike. A preview in 6.2. Revisit on Swift 6.4. |

### How the preference applies

| Option | Live? | Scope | Risk |
|---|---|---|---|
| P1. Write `AppleLanguages` to the app domain, then relaunch | No | All: SwiftUI, Foundation, AppKit menus and alerts | The user must relaunch. |
| P2. `.environment(\.locale, ...)` on the root view | Yes | SwiftUI `Text` only (fact 17) | Mixed languages in `String(localized:)`, AppKit, and alerts. Unconfirmed on macOS 14. Also changes number and date format. |

## Recommendation

Use option A and P1. They need no change to `Package.swift` or `scripts/bundle.sh`. They use `Bundle.main`, which every module reads by default.

### Files

```
Support/Resources/
  en.lproj/Localizable.strings    "Record" = "Record";
  es.lproj/Localizable.strings    "Record" = "Grabar";
  es.lproj/InfoPlist.strings      (exists)
```

- The key is the English text. `Text("Record")` shows the key if a table is missing, so English is always safe.
- Keep `en.lproj/Localizable.strings` with every key. The test compares the key sets.
- Add `Localizable.stringsdict` in each `.lproj` for the first plural string. Move to option B if plurals become common.
- `Support/Info.plist` already has `CFBundleDevelopmentRegion = en` and `CFBundleLocalizations = [en, es]`. Keep them.

### Package.swift and bundle.sh

- `Package.swift`: no change. Do not add `defaultLocalization` or `resources:`.
- `scripts/bundle.sh`: no change. `cp -R Support/Resources/. "$APP/Contents/Resources/"` copies the tables.

### Views

- Write `Text("Record")`, `Button("Record")`, `Label("Record", systemImage: ...)`. Do not pass `bundle:`.
- Use `Text(verbatim:)` or a `String` variable for user data (track names, file names).
- Use interpolation for counts: `Text("\(count) tracks")`, key `"%lld tracks"`.
- Under `swift run` or `swift test`, `Bundle.main` has no tables. Views show the English key. This is acceptable.

### Language preference

- A `Picker` in Settings has three values: macOS language, English, Spanish.
- Write the choice to the app domain:
  - macOS language: `UserDefaults.standard.removeObject(forKey: "AppleLanguages")`.
  - English: `UserDefaults.standard.set(["en"], forKey: "AppleLanguages")`.
  - Spanish: `UserDefaults.standard.set(["es"], forKey: "AppleLanguages")`.
- Read the current choice with `UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier!)?["AppleLanguages"]`. No key means "macOS language" (fact 15).
- Show the text "Restart Dirigible to apply the language." (English and Spanish). Offer a "Restart now" button (optional).
- This is the same key that `defaults write` and (unconfirmed) the System Settings per-app language use. The two stay in agreement.
- Do not use `.environment(\.locale, ...)` for the language. Keep it for region formatting only, if at all.
- Put the mapping (choice to `[String]?`) in a small pure function. A unit test covers the three cases.

### Tests

1. `LocalizationTests` in `make test` (fast, no app build):
   - Read `Support/Resources/en.lproj/Localizable.strings` and `es.lproj/Localizable.strings` from the repo with `PropertyListSerialization`. Find the repo root from `#filePath`.
   - Expect the same key set in both files.
   - Expect no empty value.
   - Expect each English value to equal its key, or list the exceptions.
2. `AppBundleTests` in `make test-app`:
   - Open `Bundle(url: app)`. Expect `localizations` to contain `en` and `es`.
   - Open `Contents/Resources/es.lproj` as a `Bundle`. Expect `localizedString(forKey: "Record", value: nil, table: nil) == "Grabar"` (use the first real key).
3. Optional source scan (a test, not a new tool): find `Text("…")`, `Button("…")`, and `Label("…"` literals in `Sources/` with a regex. Expect each key without interpolation in the English table. Ceiling: it misses interpolated keys and other initializers. Add it when the UI has more than a few screens.
4. Manual check in the run ledger: launch with `-AppleLanguages "(es)"` and look at the window.

### Revisit

- On Swift 6.4, Swift Build is the default (fact 7). Then a String Catalog in SwiftPM resources is possible. Check the `.app` layout and the `Bundle.module` path again before a change.

## Sources

1. Apple, `Text.init(_:tableName:bundle:comment:)`: "If `nil`, use the main bundle." https://developer.apple.com/documentation/swiftui/text/init(_:tablename:bundle:comment:)
2. Apple, `LocalizedStringKey`. https://developer.apple.com/documentation/swiftui/localizedstringkey
3. Apple, Localizing package resources (`defaultLocalization`, `.lproj`, `Bundle.module`). https://developer.apple.com/documentation/xcode/localizing-package-resources
4. SwiftPM issue 6993, "Bundle.module is not generated if Resources only has xcstrings file". https://github.com/swiftlang/swift-package-manager/issues/6993 ; Elegant Chaos, "Localizable String Catalogues in Swift Packages" (2026-02-12): `swift build` does not process `.xcstrings`. https://elegantchaos.com/2026/02/12/string-catalogues.html
5. Swift.org, "Swift 6.4 Released" (2026-09-15): "Swift Build is now the default in Swift Package Manager." https://www.swift.org/blog/swift-6.4-released/
6. Swift Forums, "SwiftPM on Swift Build - October Update" (default switch plan). https://forums.swift.org/t/swiftpm-on-swift-build-october-update/82889
7. Apple Support, "Change Language & Region Apps preferences on Mac". https://support.apple.com/en-za/guide/mac-help/mchlddb13d65/mac
8. Apple, Bundling resources with a Swift package (`Bundle.module`). https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package
9. Spike: copies of the repo in a temporary folder, `l10n-spike` (native build, apps `build/A.app` and `build/B.app`) and `l10n-spike-sb` (Swift Build).
