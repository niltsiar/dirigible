import DirigibleAudio
import Foundation
import Testing

@testable import DirigibleApp

/// Export run criterion 29: the pop-ups of the save panel give the export options and the file
/// extension, and each change is stored at once, so a Cancel of the panel keeps it.
@MainActor struct ExportSettingsTests {
    let name = "ExportSettingsTests-\(UUID().uuidString)"

    @Test func theOptionsMapAndComeBack() throws {
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ExportSettings(defaults: defaults)
        #expect(
            settings.options
                == ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .session, loudness: .podcast))
        #expect(settings.fileExtension == "wav" && settings.contentType.preferredFilenameExtension == "wav")

        settings.format = .flac
        settings.bits = .bits16
        #expect(settings.options.format == .flac(.bits16) && settings.fileExtension == "flac")
        settings.format = .aac
        settings.bitRate = .k96
        settings.layout = .mono
        settings.rate = .hz44100
        #expect(
            settings.options == ExportOptions(format: .aac(.k96), layout: .mono, rate: .hz44100, loudness: .podcast))
        #expect(settings.fileExtension == "m4a" && settings.contentType.preferredFilenameExtension == "m4a")

        // The panel closes with Cancel: nothing else runs. The next panel shows the same values.
        let again = ExportSettings(defaults: defaults)
        #expect(again.options == ExportOptions(format: .aac(.k96), layout: .mono, rate: .hz44100, loudness: .podcast))
        again.format = .wav
        again.rate = .hz48000
        #expect(
            ExportSettings(defaults: defaults).options
                == ExportOptions(format: .wav(.bits16), layout: .mono, rate: .hz48000, loudness: .podcast))
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
