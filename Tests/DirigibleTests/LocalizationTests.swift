import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp

/// Each string table holds every `L10n` key and nothing else, with a value and the format
/// specifiers of English (decision 0010). `AppBundleTests` checks the tables in the built bundle.
struct LocalizationTests {
    @Test func everyTableMatchesTheKeys() throws {
        var tables: [String: [String: String]] = [:]
        for language in AppLanguage.allCases.map(\.rawValue) { tables[language] = try stringsTable(language) }
        #expect(tableProblems(tables, keys: L10n.allCases.map(\.rawValue)) == [])
    }

    /// T11: each key of the template texts is in each of the eight tables, with its value.
    @Test(arguments: AppLanguage.allCases.map(\.rawValue))
    func eachTemplateKeyHasAValue(language: String) throws {
        let keys = [
            "session.template.label", "session.template.none", "session.template.show.finder", "template.save.keeps",
            "template.save.keeps.one", "template.save.keeps.none", "template.save.title", "template.save.button",
            "template.replace.title", "template.replace.info", "template.replace.replace", "menu.file.save.template",
            "menu.file.show.templates", "sheet.template.title", "start.template.copying", "error.template.pending",
            "error.template.file", "error.template.changed", "error.template.missing", "error.template.download",
            "error.template.space", "error.template.write", "error.template.exists", "error.template.trash",
        ]
        let table = try stringsTable(language)
        #expect(keys.filter { table[$0]?.isEmpty != false } == [], "\(language) lacks a template text")
        #expect(L10n.allCases.map(\.rawValue).filter { keys.contains($0) }.sorted() == keys.sorted())
    }

    @Test func checkerFindsAMissingKeyInAnyLanguage() {
        let problems = tableProblems(
            [
                "en": ["a.one": "One %@", "a.two": "Two", "a.peak": "Peak %.1f dB", "a.swap": "Files: %lld (%@)"],
                "de": ["a.one": "Uno %lld", "a.peak": "Spitze %d dB", "a.swap": "(%@) Dateien: %lld"],
                "fr": [
                    "a.one": "Un %@", "a.two": "Deux", "a.peak": "Pic %.1f dB", "a.swap": "Fichiers : %lld (%@)",
                    "a.extra": "Plus",
                ],
            ], keys: ["a.one", "a.two", "a.peak", "a.swap"])
        #expect(
            problems == [
                "de: no value for a.two", "fr: key a.extra is not in L10n",
                "a.one: specifiers [\"%@\"] in en, [\"%lld\"] in de",
                "a.peak: specifiers [\"%.1f\"] in en, [\"%d\"] in de",
                "a.swap: specifiers [\"%lld\", \"%@\"] in en, [\"%@\", \"%lld\"] in de",
            ])
    }

    @Test func checkerKeepsAPositionalReorderAndAFlaggedSpecifier() {
        let problems = tableProblems(
            [
                "en": ["a.pos": "%1$lld of %2$@", "a.gain": "Gain %+.1f dB", "a.pct": "100%% done %@"],
                "de": ["a.pos": "%2$@: %1$lld", "a.gain": "Pegel %+.1f dB", "a.pct": "100%% fertig %@"],
            ], keys: ["a.pos", "a.gain", "a.pct"])
        #expect(problems == [])
    }

    /// A value ends in the ellipsis character (U+2026) exactly when its English value does: a menu
    /// title that opens a window keeps it in each language.
    @Test func checkerFindsALostEllipsis() {
        let english = ["a.open": "Open\u{2026}", "a.save": "Save"]
        let lost = tableProblems(
            ["en": english, "de": ["a.open": "Öffnen", "a.save": "Sichern\u{2026}"]], keys: ["a.open", "a.save"])
        #expect(lost == ["a.open: ellipsis in en, none in de", "a.save: no ellipsis in en, one in de"])
        let kept = tableProblems(
            ["en": english, "de": ["a.open": "Öffnen\u{2026}", "a.save": "Sichern"]], keys: ["a.open", "a.save"])
        #expect(kept == [])
    }

    /// Each `*.lproj` folder of `Support/Resources` is a language of `AppLanguage`, with the
    /// files that the build needs (decision 0010): no `.stringsdict`, and an `InfoPlist.strings`
    /// in each folder but English.
    @Test func eachLanguageHasItsFolder() throws {
        let languages = AppLanguage.allCases.map(\.rawValue)
        let names = try FileManager.default.contentsOfDirectory(atPath: resourcesFolder.path)
        let folders = names.filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) }.sorted()
        var problems: [String] = []
        for language in languages where !folders.contains(language) { problems.append("\(language): no folder") }
        for folder in folders where !languages.contains(folder) { problems.append("\(folder): not in AppLanguage") }
        for language in languages where folders.contains(language) {
            let files = try FileManager.default.contentsOfDirectory(
                atPath: resourcesFolder.appending(path: "\(language).lproj").path
            ).filter { !$0.hasPrefix(".") }.sorted()
            let expected = language == "en" ? ["Localizable.strings"] : ["InfoPlist.strings", "Localizable.strings"]
            if files != expected { problems.append("\(language): files \(files), expected \(expected)") }
        }
        #expect(problems == [])
    }

    /// A doubled backslash in a table shows as a backslash and an n in the alert, not as a new line.
    @Test func noValueHoldsABackslashBeforeN() throws {
        for language in AppLanguage.allCases.map(\.rawValue) {
            let broken = try stringsTable(language).filter { $0.value.contains("\\n") }.keys.sorted()
            #expect(broken == [], "\(language) shows a backslash and n")
        }
    }

    /// P16 (run 2026-10-28-pre-roll): the output term alert quotes the titles of Record and Record
    /// with Pre-roll as the Record menu shows them, in each language.
    @Test(arguments: AppLanguage.allCases.map(\.rawValue))
    func theOutputTermAlertQuotesTheMenuTitles(language: String) throws {
        let table = try stringsTable(language)
        let alert = try #require(table[L10n.errorOutputTermUnavailable.rawValue])
        for key in [L10n.menuRecordStart, .menuRecordPreRoll] {
            let title = try #require(table[key.rawValue])
            #expect(alert.contains(title), "\(language): the alert does not quote \(title)")
        }
    }

    /// A pt-PT value has no word of the Brazil-only list: the pt table has them, and a copy of its
    /// text is the likely mistake. The list is words, not a `-ndo` pattern, because that also ends
    /// `quando` and `segundo`. `docs/research/pt-pt-ui.md` names the source of the list.
    @Test func theEuropeanTableHasNoBrazilianWord() throws {
        let inline = [
            "a": "Salvar", "b": "Guardar", "c": "A salvaguarda", "d": "Exportando", "e": "A exportar", "f": "Mídias",
            "g": "Tem certeza de que quer sair?",
        ]
        let inlineHits = try brazilianWordHits(in: inline)
        #expect(inlineHits == ["a: Salvar", "d: Exportando", "g: Tem certeza"])

        var table = try stringsTable("pt-PT")
        let infoPlist = resourcesFolder.appending(path: "pt-PT.lproj/InfoPlist.strings")
        let permissions = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoPlist), format: nil)
        table.merge(try #require(permissions as? [String: String])) { first, _ in first }
        let hits = try brazilianWordHits(in: table)
        #expect(hits.isEmpty, "\(hits)")
    }

    /// The Mute and Solo boxes of a track header are 18 x 16 pt (decision 0039).
    @Test func eachHeaderLetterIsOneCharacter() throws {
        for language in AppLanguage.allCases.map(\.rawValue) {
            let table = try stringsTable(language)
            for key in [L10n.trackMuteLetter, .trackSoloLetter] {
                #expect(table[key.rawValue]?.count == 1, "\(language) \(key.rawValue)")
            }
        }
    }

    /// `HeaderStateLineTests` sets the table that `.text` reads, so a row text drawn with
    /// `Text(x.key)` shows its dotted key there (decision 0010, **Views**). Help and VoiceOver
    /// texts keep `.key`.
    @Test func eachHeaderRowTextReadsTheTable() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/DirigibleApp/Timeline").standardized
        var keyTexts: [String] = []
        for name in ["TrackHeaders.swift", "TrackHeaderStates.swift", "TrackToggles.swift"] {
            let source = try String(contentsOf: folder.appending(path: name), encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for match in line.matches(of: /Text\(\s*[\w.]+\.key\s*\)/)
                where line[..<match.range.lowerBound].firstMatch(of: /\.(help|accessibility\w*)\((\w+:\s*)?$/) == nil {
                    keyTexts.append("\(name) line \(index + 1): \(match.output)")
                }
            }
        }
        #expect(keyTexts == [])
    }

    /// Crossfades F2b: the window never makes a crossfade error, so each one shows the text of a
    /// refused change (code gate 1).
    @Test func eachCrossfadeErrorShowsTheRefusedChangeText() {
        for error in [
            SessionError.crossfadeOutsideFile("B", needed: 480), .crossfadeWithoutJoin("A"),
            .crossfadeAtSeamlessJoin("A"), .crossfadeAtEqualGains("A"),
            .fadeAtCrossfade("A"),
        ] {
            #expect(L10n.message(for: .session(error)) == L10n.errorSessionOther.text, "\(error)")
        }
    }

    /// Code gate item E6. An MP3 chapter time is 32-bit in ms: at most about 49.7 days.
    @Test func theMP3ChapterLimitSaysAbout49Point7Days() throws {
        let texts = [
            "en": "An MP3 file with chapters is at most about 49.7 days long. Export a smaller selection.",
            "es": "Un archivo MP3 con capítulos dura como máximo unos 49,7 días. Exporta una selección más pequeña.",
        ]
        for (language, text) in texts {
            #expect(try stringsTable(language)[L10n.errorExportChaptersTooLong.rawValue] == text, "\(language)")
        }
    }

    /// D18: the texts that only the announcement of an Auto Level reads have `announce.` keys, one for 1
    /// clip and one for more (decision 0010, **Voice**), and the table has no `banner.` copy of them.
    @Test func theLevelChangedAnnouncementHasATextForOneClip() throws {
        let texts = [
            "en": ["Changed 1 clip.", "Changed %lld clips."],
            "es": ["Se cambió 1 clip.", "Se cambiaron %lld clips."],
        ]
        for language in AppLanguage.allCases.map(\.rawValue) {
            let table = try stringsTable(language)
            let one = try #require(table["announce.level.changed.one"], "\(language)")
            let many = try #require(table["announce.level.changed"], "\(language)")
            if let expected = texts[language] { #expect([one, many] == expected, "\(language)") }
            #expect(!one.contains("%lld") && many.contains("%lld"), "\(language): \(one) \(many)")
            #expect(table["banner.level.changed"] == nil && table["banner.level.changed.one"] == nil, "\(language)")
        }
    }

    /// D18: the texts that only the announcement of an export set or a sync reads have `announce.` keys,
    /// and the table has no `banner.` copy of them.
    @Test func theSyncAndExportResultTextsHaveAnnounceKeys() throws {
        let moved = [
            "banner.export.set.done": "announce.export.set.done",
            "banner.export.set.loudness": "announce.export.set.loudness",
            "banner.sync.earlier": "announce.sync.earlier",
            "banner.sync.later": "announce.sync.later",
            "banner.drift.corrected": "announce.drift.corrected",
            "banner.drift.split": "announce.drift.split",
        ]
        for language in AppLanguage.allCases.map(\.rawValue) {
            let table = try stringsTable(language)
            for (old, new) in moved.sorted(by: { $0.key < $1.key }) {
                #expect(table[new] != nil && table[old] == nil, "\(language): \(old) to \(new)")
            }
        }
        let en = try stringsTable("en")
        #expect(en["announce.sync.later"] == "Moved the clip %@ later.")
    }

    /// The announcement after Remove Unused Files has one text for 1 file and one for more, so 1 does
    /// not read "1 files" (decision 0010, **Voice**). The text for 1 file has no count specifier.
    @Test func theMovedAnnouncementHasATextForOneFile() throws {
        let texts = [
            "en": ["Moved 1 file to the Trash (%@).", "Moved %lld files to the Trash (%@)."],
            "es": ["Se movió 1 archivo a la Papelera (%@).", "Se movieron %lld archivos a la Papelera (%@)."],
        ]
        for language in AppLanguage.allCases.map(\.rawValue) {
            let table = try stringsTable(language)
            let one = try #require(table[L10n.announceUnusedMovedOne.rawValue], "\(language)")
            let many = try #require(table[L10n.announceUnusedMoved.rawValue], "\(language)")
            if let expected = texts[language] { #expect([one, many] == expected, "\(language)") }
            #expect(one.contains("1 ") && !one.contains("%lld") && one.contains("%@"), "\(language): \(one)")
            #expect(many.contains("%lld") && many.contains("%@"), "\(language): \(many)")
        }
    }

    /// The fill announcement puts no noun after the count, so 1 does not read "with 1 clips"
    /// (decision 0010: avoid a plural). The count comes last, after its own clip label.
    @Test func theFillTextHasNoNounAfterTheCount() throws {
        #expect(try stringsTable("en")[L10n.fillDone.rawValue] == "Filled %1$@ seconds. Clips: %2$lld")
        #expect(try stringsTable("es")[L10n.fillDone.rawValue] == "Rellenados %1$@ segundos. Clips: %2$lld")
        for language in AppLanguage.allCases.map(\.rawValue) {
            let table = try stringsTable(language)
            let text = try #require(table[L10n.fillDone.rawValue], "\(language)")
            #expect(text.contains("%1$@") && text.hasSuffix("%2$lld"), "\(language): \(text)")
        }
    }

    @Test func checkerFindsAnEmptyValue() {
        #expect(tableProblems(["en": ["a": "A"], "es": ["a": ""]], keys: ["a"]) == ["es: no value for a"])
    }
}

private let resourcesFolder = URL(filePath: #filePath).deletingLastPathComponent()
    .appending(path: "../../Support/Resources").standardized

/// The `<file>.strings` table of `language` in `Support/Resources`.
func stringsTable(_ language: String, file: String = "Localizable") throws -> [String: String] {
    let data = try Data(contentsOf: resourcesFolder.appending(path: "\(language).lproj/\(file).strings"))
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
}

/// Words and phrases that Brazilian Portuguese uses and Apple's European Portuguese never does:
/// Brazil-only nouns, `gravando` and `salvando`, and the progressive gerunds and verbs that the pt
/// table has (a European progress text reads `A <infinitive>`).
private let brazilianWords = [
    "você", "arquivo", "arquivos", "salvar", "salvo", "salvando", "tela", "telas", "usuário", "usuários",
    "trilha", "trilhas", "pista", "pistas", "mídia", "download", "gravando", "tem certeza",
    "reduzindo", "recuperando", "preparando", "posicionando", "nivelando", "importando", "finalizando",
    "exportando", "dividindo", "colando", "aguardando", "abaixando", "encerrar", "exibir", "atualizando",
    "carregando", "processando",
]

/// `key: word` for each whole-word hit of `brazilianWords` in a value, in the order of the keys. A
/// word inside another word (`salvaguarda`) is no hit; the case does not matter.
private func brazilianWordHits(in table: [String: String]) throws -> [String] {
    let words = try Regex("\\b(?:" + brazilianWords.joined(separator: "|") + ")\\b").ignoresCase()
    return table.sorted { $0.key < $1.key }.flatMap { key, value in
        value.matches(of: words).map { "\(key): \(value[$0.range])" }
    }
}

/// The problems of the tables against the keys, in a stable order: per table (by language code),
/// the missing or empty values, then the extra keys; then the keys whose specifiers or final
/// ellipsis (U+2026) differ from English.
func tableProblems(_ tables: [String: [String: String]], keys: [String]) -> [String] {
    let ordered = tables.sorted { $0.key < $1.key }
    var problems: [String] = []
    for (language, table) in ordered {
        for key in keys where table[key]?.isEmpty != false { problems.append("\(language): no value for \(key)") }
        for key in table.keys.sorted() where !keys.contains(key) {
            problems.append("\(language): key \(key) is not in L10n")
        }
    }
    let english = tables["en"] ?? [:]
    for key in keys {
        for (language, table) in ordered where language != "en" {
            guard let reference = english[key], let value = table[key] else { continue }
            let (a, b) = (specifiers(reference), specifiers(value))
            if a != b { problems.append("\(key): specifiers \(a) in en, \(b) in \(language)") }
            let ellipsis = "\u{2026}"
            if reference.hasSuffix(ellipsis) != value.hasSuffix(ellipsis) {
                problems.append(
                    reference.hasSuffix(ellipsis)
                        ? "\(key): ellipsis in en, none in \(language)"
                        : "\(key): no ellipsis in en, one in \(language)")
            }
        }
    }
    return problems
}

/// The format specifiers of a value in their order, without `%%`. They are sorted only when each
/// one has an index (`%1$@`): a positional reorder is allowed, an unpositioned word-order swap is
/// not, because `String(format:)` reads the arguments in order.
private func specifiers(_ value: String) -> [String] {
    let found = value.replacing("%%", with: "")
        .matches(of: /%(\d+\$)?[-+ 0#]*\d*(\.\d+)?(ll|l)?[@dfsu]/).map { String($0.output.0) }
    return found.allSatisfy { $0.contains("$") } ? found.sorted() : found
}
