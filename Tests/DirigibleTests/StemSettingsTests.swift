import DirigibleAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp

/// The accessory of the stem save panel (decision 0078): its own remembered values that start from
/// the export values, the role titles of the app language, and the folder name limit.
@MainActor struct StemSettingsTests {
    let name = "StemSettingsTests-\(UUID().uuidString)"

    @Test func theAccessoryKeepsItsOwnDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = StemSettings(defaults: defaults)
        #expect(fresh.options == StemOptions(format: .wav(.bits24), layout: .stereo, rate: .session))
        #expect(fresh.grouping == .track, "a new panel groups by track")

        defaults.set("mp3", forKey: "export.format")
        defaults.set(16, forKey: "export.bits")
        defaults.set("mono", forKey: "export.channels")
        defaults.set("48000", forKey: "export.rate")
        let started = StemSettings(defaults: defaults)
        #expect(
            started.options == StemOptions(format: .wav(.bits16), layout: .mono, rate: .hz48000),
            "the values start from the export values, and an MP3 export format gives WAV")
        defaults.set("flac", forKey: "export.format")
        #expect(StemSettings(defaults: defaults).options.format == .flac(.bits16), "a FLAC export format gives FLAC")

        started.format = .flac
        started.bits = .bits24
        started.layout = .stereo
        started.rate = .hz44100
        started.grouping = .role
        #expect(defaults.string(forKey: "export.format") == "flac", "the export values do not change")
        #expect(defaults.integer(forKey: "export.bits") == 16)
        #expect(defaults.string(forKey: "export.channels") == "mono")
        #expect(defaults.string(forKey: "export.rate") == "48000")
        defaults.set("wav", forKey: "export.format")
        let again = StemSettings(defaults: defaults)
        #expect(again.options == StemOptions(format: .flac(.bits24), layout: .stereo, rate: .hz44100))
        #expect(again.grouping == .role, "the next panel shows its own values")
    }

    @Test func theRoleTitlesComeFromTheLanguage() throws {
        func titles(_ language: String) throws -> StemTitles {
            let table = try stringsTable(language)
            return StemTitles.app { table[$0.rawValue] ?? $0.rawValue }
        }
        #expect(try titles("en") == .english, "the English table gives the titles of the CLI")
        #expect(
            try titles("es")
                == StemTitles(dialogue: "Diálogo", music: "Música", effects: "Efectos", none: "Sin función"))
    }

    @Test func aFolderNameOverTheLimitIsRefused() {
        let limit = stemFolderNameLimit
        #expect(stemFolderNameProblem(String(repeating: "a", count: limit)) == nil, "206 bytes pass")
        #expect(
            stemFolderNameProblem(String(repeating: "a", count: limit + 1)) == L10n.panelStemsNameTooLong.format(limit),
            "207 bytes are refused with the localized text")
        let wide = String(repeating: "é", count: limit / 2)
        #expect(
            wide.utf8.count == limit && stemFolderNameProblem(wide) == nil, "the limit counts bytes, not characters")
        #expect(stemFolderNameProblem(wide + "é") != nil)
    }
}
