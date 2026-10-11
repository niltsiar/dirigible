import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 2026-10-11-ui-polish-header C1 and C2: the header row shows a short state, and the full
/// sentence is the help tag and the VoiceOver label. The test runner has no string table, so
/// `L10n` gives the keys; the tables give the texts that the user reads.
@Suite struct HeaderStateTextTests {
    @Test func theNoSoundTextIsShort() throws {
        let state = HeaderStateText.noSound("Zoom")
        #expect(state.row == L10n.trackStateNoSoundShort.format("Zoom"))
        #expect(state.full == L10n.trackStateNoSound.format("Zoom"))
        for (language, row) in [("en", "No sound from Zoom"), ("es", "Sin sonido de Zoom")] {
            let format = try #require(try stringsTable(language)[L10n.trackStateNoSoundShort.rawValue])
            #expect(String(format: format, "Zoom") == row, "\(language)")
        }
    }

    @Test func theQuietTextIsShort() throws {
        let quiet = try #require(HeaderStateText.quiet(live: nil, quiet: true, loopback: false))
        let loopback = try #require(HeaderStateText.quiet(live: nil, quiet: false, loopback: true))
        #expect(quiet.row == L10n.trackListenQuietShort.text && loopback.row == L10n.trackListenQuietShort.text)
        #expect(quiet.full == L10n.trackListenQuiet.text)
        #expect(loopback.full == L10n.trackListenLoopback.text)
        #expect(HeaderStateText.quiet(live: nil, quiet: false, loopback: false) == nil, "a track that plays")
        for (language, row) in [("en", "No monitor sound"), ("es", "Sin sonido de monitor")] {
            #expect(try stringsTable(language)[L10n.trackListenQuietShort.rawValue] == row, "\(language)")
        }
    }
}
