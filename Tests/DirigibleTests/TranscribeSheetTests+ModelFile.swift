import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The model file of the user in the Transcribe sheet (decision 0065 D8, C17 to C19, C26): the
/// pop-up entries, the kept file, the check line, the model memory, and the English-only rule.
extension TranscribeSheetTests {
    static let medium = WhisperModelFacts(audioLayers: 24, textLayers: 24, melCount: 80, isMultilingual: true)
    static let englishOnly = WhisperModelFacts(audioLayers: 4, textLayers: 4, melCount: 80, isMultilingual: false)

    static func kept(_ facts: WhisperModelFacts = medium, bytes: Int = 1_533_774_781) -> KeptModelFile {
        KeptModelFile(
            url: URL(fileURLWithPath: "/Models/ggml-medium.bin"),
            status: FileStatus(byteCount: bytes, modified: Date(timeIntervalSince1970: 1_000)),
            passed: PassedModelFile(sha256: String(repeating: "a", count: 64), facts: facts))
    }

    static func sheet(
        _ language: WhisperLanguage, kept: KeptModelFile? = nil, remembered: ModelEntry? = nil, words: Int = 0
    ) throws -> TranscribeDraft {
        try #require(
            TranscribeDraft(
                tracks: [TranscribeDraft.Choice(id: "t1", name: "Host", words: words)], selected: nil,
                onDisk: [.base, .smallQ51], language: language, kept: kept,
                remembered: remembered))
    }

    /// C17: the live panel takes any file, one file, and no folder.
    @MainActor @Test func theModelPanelTakesAnyFile() {
        let panel = TranscribeState.modelPanel()
        #expect(panel.allowedContentTypes.isEmpty)
        #expect(panel.canChooseFiles && !panel.canChooseDirectories && !panel.allowsMultipleSelection)
    }

    /// C17: a file over 500,000,000 bytes adds the wait line; a file of 500,000,000 bytes does not.
    @Test func aFileOverHalfAGigabyteAddsTheWaitLine() {
        let wait = L10n.sheetTranscribeCheckWait.text
        #expect(ModelCheckLine.running(name: "a.bin", byteCount: 500_000_001).text.hasSuffix(" " + wait))
        #expect(!ModelCheckLine.running(name: "a.bin", byteCount: 500_000_000).text.contains(wait))
    }

    /// C18: the catalog entries, a divider, the kept file, a divider, and Choose Model File...;
    /// the label is the name and the Finder size. Control: with no kept file, one divider.
    @Test func theKeptFileSitsBetweenTwoDividers() throws {
        let entries = try Self.sheet(.code("en"), kept: Self.kept()).entries
        let catalog = TranscribeDraft.models.map { ModelEntry.catalog($0) }
        #expect(entries == catalog + [nil, .file, nil, .choose])
        #expect(try Self.sheet(.code("en")).entries == catalog + [nil, .choose])
        let label = Self.kept().title(
            missing: false, locale: Locale(identifier: "en_US"),
            text: { $0 == .sheetTranscribeFileTitle ? "%1$@ - %2$@" : $0.text })
        #expect(label == "ggml-medium.bin - 1.53 GB")
        #expect(Self.kept().title(missing: true) == L10n.sheetTranscribeMissing.format("ggml-medium.bin"))
    }

    /// C19: the kept file gives the facts of its record and the note; a catalog entry gives no
    /// note of a model file.
    @Test func theKeptFileShowsItsFactsAndTheNote() throws {
        var draft = try Self.sheet(.code("en"), kept: Self.kept(), remembered: .file)
        #expect(draft.model == .file)
        #expect(draft.modelNotes == [ModelCheckLine.text(of: Self.medium), L10n.sheetTranscribeNoteFile.text])
        draft.select(.catalog(.base))
        #expect(!draft.modelNotes.contains(L10n.sheetTranscribeNoteFile.text))
        draft.check = .running(name: "x.bin", byteCount: 1)
        #expect(!draft.canStart)
    }

    /// C19: the first selection per language choice. (a) no job: Spanish More Accurate, German
    /// Standard; (b) a remembered Standard for Spanish; (f) a remembered kept file that is gone
    /// gives the language rule; (g) a language change keeps the model.
    @Test func theFirstModelFollowsTheMemoryElseTheLanguage() throws {
        #expect(try Self.sheet(.code("es")).model == .catalog(.smallQ51))
        #expect(try Self.sheet(.code("de")).model == .catalog(.base))
        #expect(try Self.sheet(.code("es"), remembered: .catalog(.base)).model == .catalog(.base))
        #expect(try Self.sheet(.code("es"), remembered: .file).model == .catalog(.smallQ51), "no kept file")
        var missing = try Self.sheet(.code("es"), kept: Self.kept(), remembered: .file)
        missing.keptFileIsMissing()
        #expect(missing.model == .catalog(.smallQ51) && missing.keptMissing && missing.canStart)
        var changed = try Self.sheet(.code("es"))
        changed.language = .code("de")
        #expect(changed.model == .catalog(.smallQ51))
    }

    /// C19: the memory is per language choice, Automatic as one choice. (c) an English job with
    /// the kept file, then a Spanish sheet: More Accurate; (d) an Automatic job with Most Accurate:
    /// an Automatic sheet starts there and an English sheet at Standard.
    @Test func theMemoryIsPerLanguageChoice() throws {
        let suite = "TranscribeSheetTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let turbo = try #require(WhisperModel(rawValue: "large-v3-turbo-q5_0"))
        var english = try Self.sheet(.code("en"), kept: Self.kept(), remembered: nil)
        english.select(.file)
        english.remember(in: defaults)
        var automatic = try Self.sheet(.automatic)
        automatic.select(.catalog(turbo))
        automatic.remember(in: defaults)

        func first(_ language: WhisperLanguage) throws -> ModelEntry {
            try Self.sheet(
                language, kept: Self.kept(), remembered: TranscribeModelMemory.entry(for: language, in: defaults)
            ).model
        }
        #expect(try first(.code("es")) == .catalog(.smallQ51))
        #expect(try first(.code("en")) == .file)
        #expect(try first(.automatic) == .catalog(turbo))
        #expect(try first(.code("de")) == .catalog(.base))
    }

    /// C26: an English-only file sets English and locks the pop-up; another entry gives back the
    /// language before. (d) a multilingual file leaves the pop-up on and unchanged.
    @Test(arguments: [WhisperLanguage.code("es"), .automatic])
    func anEnglishOnlyFileLocksTheLanguage(language: WhisperLanguage) throws {
        var draft = try Self.sheet(language, kept: Self.kept(Self.englishOnly))
        draft.select(.file)
        #expect(draft.language == .code("en") && draft.languageLocked)
        draft.select(.catalog(.base))
        #expect(draft.language == language && !draft.languageLocked)

        var multilingual = try Self.sheet(language, kept: Self.kept())
        multilingual.select(.file)
        #expect(multilingual.language == language && !multilingual.languageLocked)
    }

    /// C26 (c): a sheet that opens on a kept English-only file shows English, locked.
    @Test func aSheetThatOpensOnAnEnglishOnlyFileLocksTheLanguage() throws {
        let draft = try Self.sheet(.code("es"), kept: Self.kept(Self.englishOnly), remembered: .file)
        #expect(draft.model == .file && draft.language == .code("en") && draft.languageLocked)
        #expect(draft.request?.language == .code("en"))
    }

    /// Item 11: the replace note shows whenever a replace applies, also while a check line shows.
    /// Control: a track with no word has no replace note.
    @Test(arguments: [ModelCheckLine.running(name: "a.bin", byteCount: 1), .passed(medium), .refused("No.")])
    func theReplaceNoteStaysWhileTheCheckLineShows(line: ModelCheckLine) throws {
        var one = try Self.sheet(.code("en"), words: 1)
        one.check = line
        #expect(one.replaceNote == L10n.sheetTranscribeNoteReplaceOne.text)
        var many = try Self.sheet(.code("en"), words: 3)
        many.check = line
        #expect(many.replaceNote == L10n.sheetTranscribeNoteReplaceMany.format(3))
        var none = try Self.sheet(.code("en"))
        none.check = line
        #expect(none.replaceNote == nil)
    }

    /// Item 13: the kind names and the title of the kept file come from the tables.
    @Test func theKindNamesAndTheFileTitleComeFromTheTables() {
        let table: (L10n) -> String = { key in
            switch key {
            case .sheetTranscribeCheckMultilingual: "%@, multi"
            case .sheetTranscribeFileTitle: "%1$@ / %2$@"
            default: "<\(key.rawValue)>"
            }
        }
        let layers: [(Int, L10n)] = [
            (4, .sheetTranscribeKindTiny), (6, .sheetTranscribeKindBase), (12, .sheetTranscribeKindSmall),
            (24, .sheetTranscribeKindMedium), (32, .sheetTranscribeKindLarge),
        ]
        for (count, key) in layers {
            let facts = WhisperModelFacts(audioLayers: count, textLayers: count, melCount: 80, isMultilingual: true)
            #expect(ModelCheckLine.text(of: facts, text: table) == "<\(key.rawValue)>, multi")
        }
        let title = Self.kept().title(missing: false, locale: Locale(identifier: "en_US"), text: table)
        #expect(title == "ggml-medium.bin / 1.53 GB")
    }

    /// Item 15: a file entry with no kept file gives no request and does not start; a file entry
    /// with its file gives the file in the request.
    @Test func aFileEntryWithNoKeptFileGivesNoRequest() throws {
        var empty = try Self.sheet(.code("en"))
        empty.model = .file
        #expect(empty.request == nil && !empty.canStart)
        let kept = Self.kept()
        var draft = try Self.sheet(.code("en"), kept: kept)
        draft.select(.file)
        #expect(draft.request?.model == .file(kept.url, passed: kept.passed) && draft.canStart)
        draft.select(.choose)
        #expect(draft.request == nil && !draft.canStart)
    }

    /// Item 9: a moved file names the file in the Locate... alert; another read error keeps the
    /// error number.
    @Test func aMovedFileNamesTheFileInTheLocateAlert() throws {
        let draft = try Self.sheet(.code("en"), kept: Self.kept(), remembered: .file)
        let request = try #require(draft.request)
        func alert(_ code: Int32) -> WindowAlert {
            WindowAlert.transcribe(.transcription(.modelFile(.unreadable(errno: code))), request)
        }
        #expect(alert(ENOENT).text == L10n.errorTranscribeFileMissing.format("ggml-medium.bin"))
        let denied = StudioError.transcription(.modelFile(.unreadable(errno: EACCES)))
        #expect(alert(EACCES).text == L10n.message(for: denied))
    }
}
