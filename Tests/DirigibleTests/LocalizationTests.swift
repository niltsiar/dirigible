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

    /// A value equal to its English value is a missing translation unless its key is in the list
    /// of its language: units, format names, and words that are the same in the language. Each key
    /// of the list still has the English value, so the list holds no stale key.
    @Test func noValueCopiesEnglish() throws {
        let english = try stringsTable("en")
        for language in AppLanguage.allCases.map(\.rawValue) where language != "en" {
            let table = try stringsTable(language)
            let allowed = sameAsEnglish[language] ?? []
            let copies = english.keys.sorted().filter { table[$0] == english[$0] && !allowed.contains($0) }
            #expect(copies == [], "\(language) copies the English value")
            let stale = allowed.sorted().filter { table[$0] != english[$0] }
            #expect(stale == [], "\(language) lists a key whose value is not the English value")
        }
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

    /// The inspector has no room in pt: a label is `fixedSize`, and a column takes the width of its
    /// widest label. So a group of texts has a room, the widest text of the group in `en`, `es`,
    /// and `de` (rounded up), which the on-screen check at 240 pt shows whole. A text wider than
    /// its room needs a shorter value, or that check in its language and a wider room.
    @Test func eachInspectorTextFitsItsRoom() throws {
        for (name, size, room, keys) in inspectorRooms {
            for language in AppLanguage.allCases.map(\.rawValue) {
                let table = try stringsTable(language)
                for key in keys {
                    let text = try #require(table[key.rawValue], "\(language) \(key.rawValue)")
                    let font = NSFont.systemFont(ofSize: size)
                    let width = NSString(string: text).size(withAttributes: [.font: font]).width.rounded(.up)
                    #expect(width <= room, "\(language) \(key.rawValue): \(width) pt in the room \(room) pt of \(name)")
                }
            }
        }
    }

    /// Crossfades F2b: the window never makes a crossfade error, so each one shows the text of a
    /// refused change (code gate 1).
    @Test func eachCrossfadeErrorShowsTheRefusedChangeText() {
        for error in [
            SessionError.crossfadeOutsideFile("B", needed: 480), .crossfadeWithoutJoin("A"),
            .crossfadeAtSeamlessJoin("A"), .crossfadeAtEqualGains("A"),
            .fadeAtCrossfade("A"),
        ] {
            #expect(L10n.message(for: .session(error)) == L10n.errorSessionOther.rawValue, "\(error)")
        }
    }

    /// Code gate item E6. An MP3 chapter time is 32-bit in ms: at most about 49.7 days.
    @Test func theMP3ChapterLimitSaysAbout49Point7Days() throws {
        let texts = [
            "en": "An MP3 file with chapters is at most about 49.7 days long. Export a smaller selection.",
            "es": "Un archivo MP3 con capítulos dura como máximo unos 49,7 días. Exporte una selección más pequeña.",
        ]
        for (language, text) in texts {
            #expect(try stringsTable(language)[L10n.errorExportChaptersTooLong.rawValue] == text, "\(language)")
        }
    }

    /// The banner after Remove Unused Files puts no noun after the count, so 1 does not read
    /// "1 files" (decision 0010: avoid a plural).
    @Test func theMovedBannerHasNoNounAfterTheCount() throws {
        let texts = [
            "en": "Files moved to the Trash: %lld (%@).",
            "es": "Archivos trasladados a la Papelera: %lld (%@).",
        ]
        for (language, text) in texts {
            #expect(try stringsTable(language)[L10n.bannerUnusedMoved.rawValue] == text, "\(language)")
        }
        // The other languages keep the form `<words>: %lld (%@).`; French puts a space before the colon.
        for language in AppLanguage.allCases.map(\.rawValue) where texts[language] == nil {
            let text = try #require(try stringsTable(language)[L10n.bannerUnusedMoved.rawValue], "\(language)")
            #expect(text.wholeMatch(of: /[^%:]+: %lld \(%@\)\./) != nil, "\(language): \(text)")
        }
    }

    @Test func checkerFindsAnEmptyValue() {
        #expect(tableProblems(["en": ["a": "A"], "es": ["a": ""]], keys: ["a"]) == ["es: no value for a"])
    }
}

/// The inspector text groups: name, font size in pt (11 in the panes, the regular size for the tab
/// picker), room in pt, and keys.
private let inspectorRooms: [(name: String, size: Double, room: Double, keys: [L10n])] = [
    ("clip labels", 11, 50, [.inspectorGain, .inspectorFadeIn, .inspectorFadeOut]),
    ("clip units", 11, 16, [.inspectorDecibels, .inspectorMilliseconds]),
    ("clip wide label", 11, 190, [.inspectorGainAtPlayhead, .inspectorEffects, .inspectorEffectNoise]),
    (
        "episode labels", 11, 59,
        [
            .episodeTitle, .episodeShow, .episodeAuthor, .episodeSeason, .episodeNumber, .episodeDate,
            .episodeLanguage, .episodeCopyright,
        ]
    ),
    ("episode link labels", 11, 89, [.episodeURL, .episodeFeedURL, .episodeGUID]),
    ("marker labels", 11, 42, [.markerName, .markerURL]),
    ("tab titles", Double(NSFont.systemFontSize), 58, [.inspectorTabClip, .inspectorTabEpisode, .inspectorTabMarker]),
    ("Explicit", 11, 45, [.episodeExplicit]),
    ("Links", 11, 41, [.episodeLinks]),
    ("Choose", 11, 51, [.episodeArtworkChoose]),
    ("Remove", 11, 51, [.episodeArtworkRemove]),
]

private let resourcesFolder = URL(filePath: #filePath).deletingLastPathComponent()
    .appending(path: "../../Support/Resources").standardized

/// The `Localizable.strings` table of `language` in `Support/Resources`.
func stringsTable(_ language: String) throws -> [String: String] {
    let data = try Data(contentsOf: resourcesFolder.appending(path: "\(language).lproj/Localizable.strings"))
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
}

/// The keys whose value is the English value in that language, and right so (units, format names,
/// and words that are the same).
private let sameAsEnglish: [String: Set<String>] = [
    "de": [
        "split.suffix.left", "split.suffix.right",
        "inspector.tab.clip", "inspector.tab.marker", "marker.name", "marker.url", "episode.details",
        "episode.copyright", "episode.links", "episode.guid", "alert.ok", "track.name", "track.role.dialogue.letter",
        "track.role.effects.letter", "track.role.music.letter", "track.mute.letter",
        "track.solo.letter", "track.volume.value", "track.layout.mono", "track.layout.stereo",
        "track.route", "track.route.apps", "dock.badge.recording", "menu.transport", "menu.transport.pause",
        "timeline.accessibility", "timeline.readout.crossfade", "inspector.clip", "inspector.clips",
        "inspector.decibels", "inspector.milliseconds", "loudness.short", "menu.edit.fade", "agent.mark",
        "marker.default.name", "panel.export.format", "panel.export.format.wav", "panel.export.format.aac",
        "panel.export.format.mp3", "panel.export.format.flac", "panel.export.bitrate.value",
        "panel.export.channels.stereo", "panel.export.channels.mono", "panel.export.rate.48000",
        "panel.export.loudness", "panel.export.loudness.podcast", "panel.export.loudness.ebu",
        "export.chapter.intro", "sheet.unused.name", "toolbar.tooltip", "banner.kind.info", "start.version",
        "start.name", "sheet.duck.attack", "sheet.duck.release", "sheet.take.time.take", "sheet.take.time.item",
        "panel.transcript.format.srt", "panel.transcript.format.vtt", "inspector.hertz",
    ],
    "es": [
        "banner.kind.error", "dock.badge.recording", "episode.copyright", "episode.guid", "inspector.clip",
        "inspector.clips", "inspector.decibels", "inspector.milliseconds", "inspector.tab.clip",
        "panel.export.bitrate.value", "panel.export.channels.mono", "panel.export.format.aac",
        "panel.export.format.flac", "panel.export.format.mp3", "panel.export.format.wav",
        "panel.export.loudness.ebu", "panel.export.rate.48000", "toolbar.inspector", "toolbar.tooltip",
        "track.layout.mono", "track.role.dialogue.letter", "track.role.effects.letter", "track.role.music.letter",
        "track.mute.letter", "track.route", "track.route.apps", "track.solo.label",
        "track.solo.letter", "track.volume.value",
        "panel.transcript.format.srt", "panel.transcript.format.vtt", "inspector.hertz",
    ],
    "fr": [
        "agent.mark", "alert.ok", "banner.kind.info", "dock.badge.recording", "episode.copyright",
        "episode.date", "episode.description", "episode.guid", "episode.notes", "export.chapter.intro",
        "inspector.clip", "inspector.decibels", "inspector.gain", "inspector.milliseconds",
        "inspector.tab.clip", "inspector.tab.marker", "marker.image", "menu.transport",
        "menu.transport.pause", "panel.export.bitrate.value", "panel.export.channels.mono",
        "panel.export.format", "panel.export.format.aac", "panel.export.format.flac",
        "panel.export.format.mp3", "panel.export.format.wav", "panel.export.loudness.ebu",
        "panel.export.loudness.podcast", "panel.export.rate.48000", "report.gain", "start.version",
        "timeline.accessibility", "timeline.readout.gain", "timeline.readout.point", "toolbar.tooltip",
        "track.layout.mono",
        "track.role.dialogue", "track.role.dialogue.letter", "track.role.effects.letter", "track.role.music.letter",
        "track.mute.letter", "track.route", "track.route.apps", "track.solo.letter", "track.volume.value",
        "panel.transcript.format.srt", "panel.transcript.format.vtt", "inspector.hertz",
    ],
    "it": [
        "alert.ok", "dock.badge.recording", "episode.copyright", "episode.guid", "export.chapter.intro",
        "inspector.clip", "inspector.decibels", "inspector.gain", "inspector.milliseconds",
        "inspector.tab.clip", "inspector.tab.marker", "marker.url", "panel.export.bitrate.value",
        "panel.export.channels.mono", "panel.export.channels.stereo", "panel.export.format.aac",
        "panel.export.format.flac", "panel.export.format.mp3", "panel.export.format.wav",
        "panel.export.loudness.ebu", "panel.export.loudness.podcast", "panel.export.rate.48000",
        "timeline.accessibility", "toolbar.inspector", "toolbar.tooltip", "track.layout.mono",
        "track.layout.stereo", "track.role.dialogue.letter", "track.role.effects.letter", "track.role.music.letter",
        "track.mute.letter", "track.no.sound.privacy", "track.route",
        "track.solo.letter", "track.volume.value", "sheet.take.time.take", "sheet.take.time.item",
        "panel.transcript.format.srt", "panel.transcript.format.vtt", "inspector.hertz",
    ],
    "nl": [
        "split.suffix.left", "split.suffix.right",
        "agent.mark", "alert.ok", "dock.badge.recording", "episode.copyright", "episode.details",
        "episode.guid", "episode.links", "export.chapter.intro", "inspector.clip", "inspector.clips",
        "inspector.decibels", "inspector.gain", "inspector.milliseconds", "inspector.tab.clip",
        "inspector.tab.episode", "inspector.tab.marker", "marker.url", "menu.edit.fade", "menu.file.open",
        "menu.transport", "menu.transport.stop", "panel.export.bitrate.value", "panel.export.channels.mono",
        "panel.export.channels.stereo", "panel.export.format.aac", "panel.export.format.flac",
        "panel.export.format.mp3", "panel.export.format.wav", "panel.export.loudness.ebu",
        "panel.export.loudness.podcast", "panel.export.rate.48000", "timeline.readout.crossfade",
        "toolbar.tooltip", "track.layout.mono", "track.layout.stereo", "track.role.dialogue.letter",
        "track.role.effects.letter", "track.role.music.letter", "track.mute.letter",
        "track.no.sound.privacy", "track.route", "track.route.apps", "track.solo.letter",
        "track.volume.value", "transport.stop", "sheet.duck.attack", "sheet.duck.release",
        "sheet.take.time.take", "sheet.take.time.item",
        "panel.transcript.format.srt", "panel.transcript.format.vtt", "panel.transcript.choice", "inspector.hertz",
    ],
    "pt": [
        "alert.ok", "dock.badge.recording", "episode.copyright", "episode.guid", "episode.links",
        "inspector.decibels", "inspector.milliseconds", "loudness.short", "marker.url", "menu.edit.fade",
        "panel.export.bitrate.value", "panel.export.channels.mono", "panel.export.format.aac",
        "panel.export.format.flac", "panel.export.format.mp3", "panel.export.format.wav",
        "panel.export.loudness", "panel.export.loudness.ebu", "panel.export.loudness.podcast",
        "panel.export.rate.48000", "report.loudness", "timeline.readout.crossfade", "toolbar.tooltip",
        "track.layout.mono", "track.role.dialogue.letter", "track.role.effects.letter", "track.role.music.letter",
        "track.mute.letter", "track.route", "track.route.apps", "track.solo.letter",
        "track.volume.value",
        "panel.transcript.format.srt", "panel.transcript.format.vtt", "inspector.hertz",
    ],
]

/// The problems of the tables against the keys, in a stable order: per table (by language code),
/// the missing or empty values, then the extra keys; then the keys whose specifiers differ from
/// English.
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
