import DirigibleAudio
import Foundation
import Testing

@testable import DirigibleApp

/// Export run criterion 29: the pop-ups of the save panel give the export options and the file
/// extension, and each change is stored at once, so a Cancel of the panel keeps it.
@MainActor struct ExportSettingsTests {
    let name = "ExportSettingsTests-\(UUID().uuidString)"
    static var intro: String { L10n.exportChapterIntro.text }

    /// Run 2026-10-11-chapters-in-file, C5g: the M4A chapter that the export adds at the range
    /// start has the localized title, not the English default of the library.
    @Test func theExportPanelPassesTheLocalizedIntroTitle() throws {
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ExportSettings(defaults: defaults).options.introTitle == L10n.exportChapterIntro.text)
    }

    @Test func theOptionsMapAndComeBack() throws {
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ExportSettings(defaults: defaults)
        #expect(
            settings.options
                == ExportOptions(
                    format: .wav(.bits24), layout: .stereo, rate: .session, loudness: .podcast, introTitle: Self.intro))
        #expect(settings.fileExtension == "wav" && settings.contentType.preferredFilenameExtension == "wav")

        settings.format = .flac
        settings.bits = .bits16
        #expect(settings.options.format == .flac(.bits16) && settings.fileExtension == "flac")
        settings.format = .aac
        settings.bitRate = .k96
        settings.layout = .mono
        settings.rate = .hz44100
        #expect(
            settings.options
                == ExportOptions(
                    format: .aac(.k96), layout: .mono, rate: .hz44100, loudness: .podcast, introTitle: Self.intro))
        #expect(settings.fileExtension == "m4a" && settings.contentType.preferredFilenameExtension == "m4a")

        // The panel closes with Cancel: nothing else runs. The next panel shows the same values.
        let again = ExportSettings(defaults: defaults)
        #expect(
            again.options
                == ExportOptions(
                    format: .aac(.k96), layout: .mono, rate: .hz44100, loudness: .podcast, introTitle: Self.intro))
        again.format = .wav
        again.rate = .hz48000
        #expect(
            ExportSettings(defaults: defaults).options
                == ExportOptions(
                    format: .wav(.bits16), layout: .mono, rate: .hz48000, loudness: .podcast, introTitle: Self.intro))

        // MP3 run criterion 14: MP3 takes the bit rate, and comes back from the defaults.
        again.format = .mp3
        again.bitRate = .k96
        #expect(again.options.format == .mp3(.k96))
        #expect(again.fileExtension == "mp3" && again.contentType == .mp3)
        #expect(ExportSettings(defaults: defaults).options.format == .mp3(.k96))
    }

    /// Run 9a criterion 19: the loudness target is stored as a token. Off comes back as Off; a
    /// missing key or an unknown token gives Podcast.
    @Test func loudnessIsStored() throws {
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ExportSettings(defaults: defaults).loudness == .podcast, "the default")

        ExportSettings(defaults: defaults).loudness = nil
        #expect(ExportSettings(defaults: defaults).loudness == nil, "Off came back as a target")
        #expect(ExportSettings(defaults: defaults).options.loudness == nil)
        ExportSettings(defaults: defaults).loudness = .ebu
        #expect(ExportSettings(defaults: defaults).options.loudness == .ebu)
        defaults.set("loud", forKey: "export.loudness")
        #expect(ExportSettings(defaults: defaults).loudness == .podcast, "an unknown token")
    }
}
