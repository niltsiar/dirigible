import Foundation
import Testing

@testable import DirigibleApp

/// The help text of the track role (backlog item 1670): the long line of the tooltips and the
/// short header line of the Role submenu. A SwiftUI `.help` cannot be read in a unit test, so the
/// tests read the tables, as `TrackMuteSoloWindowTests` does. The on-screen check is M1 of the run.
struct RoleHelpTests {
    /// A menu title without its ellipsis character, as the help text quotes it.
    private func name(_ table: [String: String], _ key: String) -> String {
        (table[key] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\u{2026}").union(.whitespaces))
    }

    @Test func theEnglishHelpSaysTheRoleIsALabelWithNoSound() throws {
        let en = try stringsTable("en")
        let help = try #require(en["track.role.help"], "no value for track.role.help")
        #expect(help.contains("label") && help.contains("no sound"))
        #expect(help.contains("Duck Music Under Speech") && help.contains("Reduce Noise"))
        #expect(name(en, "menu.tools.duck") == "Duck Music Under Speech")
        #expect(name(en, "menu.tools.reduce.noise") == "Reduce Noise")
    }

    @Test func eachTableHelpNamesTheDuckAndReduceNoiseTitlesOfItsOwnTable() throws {
        for language in AppLanguage.allCases.map(\.rawValue) {
            let table = try stringsTable(language)
            let help = try #require(table["track.role.help"], "\(language): no value for track.role.help")
            #expect(help.contains(name(table, "menu.tools.duck")), "\(language): the duck title")
            #expect(help.contains(name(table, "menu.tools.reduce.noise")), "\(language): the Reduce Noise title")
        }
    }

    @Test func theHeaderLineIsOneShortLine() throws {
        for language in ["en", "es"] {
            let table = try stringsTable(language)
            let header = try #require(table["track.role.header"], "\(language): no value for track.role.header")
            #expect(!header.contains("\n"), "\(language): one line")
        }
        let header = try #require(try stringsTable("en")["track.role.header"])
        #expect(header.contains("label") && header.contains("sound"))
    }
}
