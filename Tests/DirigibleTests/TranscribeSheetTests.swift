import DirigibleAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp

/// Tools > Transcribe Track... (decision 0065, C20, U21): the values of the sheet.
struct TranscribeSheetTests {
    static let host = TranscribeDraft.Choice(id: "t1", name: "Host", words: 0)
    static let guest = TranscribeDraft.Choice(id: "t2", name: "Guest", words: 0)

    static func draft(
        _ tracks: [TranscribeDraft.Choice] = [host, guest], selected: TrackID? = "t2",
        onDisk: Set<WhisperModel> = [.base, .smallQ51]
    ) throws -> TranscribeDraft {
        try #require(TranscribeDraft(tracks: tracks, selected: selected, onDisk: onDisk, language: .automatic))
    }

    /// C20: with no model on disk the default button reads "Download and Transcribe", for each
    /// offered model, and the chosen track stays. Control: with the model it reads "Transcribe".
    @Test func noModelShowsTheDownload() throws {
        var draft = try Self.draft(onDisk: [])
        #expect(draft.buttonTitle == .sheetTranscribeDownload)
        draft.model = .catalog(.smallQ51)
        #expect(draft.buttonTitle == .sheetTranscribeDownload)
        #expect(draft.track == "t2" && draft.request?.track == "t2" && draft.request?.trackName == "Guest")

        let withModel = try Self.draft(onDisk: [.base])
        #expect(withModel.buttonTitle == .sheetTranscribeStart)
    }

    /// C20, C-6: a track with words makes the button "Replace" and the note counts the words of
    /// that track; the pick of another track with no word makes it "Transcribe" again.
    @Test func wordsOnTheTrackShowReplaceAndTheCount() throws {
        let spoken = TranscribeDraft.Choice(id: "t1", name: "Host", words: 42)
        var draft = try Self.draft([spoken, Self.guest], selected: "t1")
        #expect(draft.buttonTitle == .sheetTranscribeReplace && draft.words == 42)
        draft.track = "t2"
        #expect(draft.buttonTitle == .sheetTranscribeStart && draft.words == 0)
        draft.track = "t1"
        draft.model = .catalog(.smallQ51)
        #expect(draft.buttonTitle == .sheetTranscribeReplace, "both models are on disk")
        let download = try Self.draft([spoken], selected: "t1", onDisk: [.base])
        var other = download
        other.model = .catalog(.smallQ51)
        #expect(download.buttonTitle == .sheetTranscribeReplace && other.buttonTitle == .sheetTranscribeDownload)
    }

    /// C20, C-5: the sizes come from the catalog byte count in the units of the Finder, not from
    /// text ("141 MB" and "181 MB" are the MiB values).
    @Test func modelSizesAreFinderSizes() {
        let english = Locale(identifier: "en_US")
        #expect(TranscribeDraft.size(of: .base, locale: english) == "148 MB")
        #expect(TranscribeDraft.size(of: .smallQ51, locale: english) == "190.1 MB")
    }

    /// C27, C-5: the pop-up offers the three user models in catalog order, each with its English title.
    @Test func thePopUpOffersThreeModelsWithTheirTitles() throws {
        let turbo = try #require(WhisperModel(rawValue: "large-v3-turbo-q5_0"))
        #expect(TranscribeDraft.models == [.base, .smallQ51, turbo], "tiny is for tests")
        let table = try stringsTable("en")
        func title(_ model: WhisperModel) -> String {
            TranscribeDraft.title(of: model, locale: Locale(identifier: "en_US")) { table[$0.rawValue] ?? "" }
        }
        #expect(title(.base) == "Standard - 148 MB")
        #expect(title(.smallQ51) == "More Accurate - 190.1 MB, slower")
        #expect(title(turbo) == "Most Accurate - 574 MB, slowest")
    }

    /// Lead ruling C27: a sheet that opens with Spanish starts at More Accurate (small-q5_1), and a
    /// sheet with another language starts at Standard (base).
    @Test(arguments: [(WhisperLanguage.code("es"), WhisperModel.smallQ51), (.code("en"), .base), (.automatic, .base)])
    func theFirstModelFollowsTheLanguage(language: WhisperLanguage, model: WhisperModel) throws {
        let draft = try #require(TranscribeDraft(tracks: [Self.host], selected: nil, onDisk: [], language: language))
        #expect(draft.model == .catalog(model))
    }

    /// U21: the stored choice wins; else the app language when whisper supports it; else Automatic.
    @Test func theFirstLanguageFollowsTheRule() {
        let supported = ["en", "es", "pt"]
        func first(_ stored: String?, _ app: String?) -> WhisperLanguage {
            TranscribeLanguages.first(stored: stored, appLanguage: app, supported: supported)
        }
        #expect(first(nil, "es") == .code("es"))
        #expect(first(nil, "pt-PT") == .code("pt"), "a region does not matter")
        #expect(first(nil, "tlh") == .automatic)
        #expect(first(nil, nil) == .automatic)
        #expect(first("auto", "es") == .automatic, "Automatic is a choice that stays")
        #expect(first("en", "es") == .code("en"))
        #expect(first("xx", "es") == .code("es"), "a code that whisper dropped falls through")
    }

    /// C-3: the preferred languages of the user that whisper supports, in order, with no repeat.
    @Test func thePreferredLanguagesAreTheSupportedOnes() {
        let identifiers = ["es-ES", "en-US", "es-MX", "tlh", "pt-PT"]
        #expect(TranscribeLanguages.preferred(identifiers, supported: ["en", "es"]) == ["es", "en"])
        let all = WhisperLanguage.codes
        #expect(all.count > 90 && all.contains("es") && all.contains("en"), "\(all.count) codes")
        // alemán, español, francés
        #expect(
            TranscribeLanguages.byName(["fr", "es", "de"], locale: Locale(identifier: "es")) == ["de", "es", "fr"])
    }

    /// Later uses keep the last choice, Automatic too.
    @Test(arguments: [WhisperLanguage.automatic, .code("de")])
    func theChoiceRoundTripsThroughTheDefaults(language: WhisperLanguage) throws {
        let suite = "TranscribeSheetTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var draft = try Self.draft()
        draft.language = language
        draft.remember(in: defaults)
        let stored = defaults.string(forKey: TranscribeDraft.languageKey)
        #expect(TranscribeLanguages.first(stored: stored, appLanguage: "es") == language)
    }
}
