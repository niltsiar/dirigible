import DirigibleAudio
import DirigibleCore
import SwiftUI

/// What a transcription job needs. The window keeps it for Transcribe Again.
struct TranscribeRequest: Hashable {
    let track: TrackID
    let trackName: String
    let language: WhisperLanguage
    let model: WhisperModel
}

/// The values of the Tools > Transcribe Track... sheet (decision 0065, UI council C-2 to C-6).
struct TranscribeDraft: Equatable {
    static let languageKey = "transcribe.language"
    /// The models that the sheet offers: each catalog model with a title, in catalog order.
    static var models: [WhisperModel] { WhisperModel.allCases.filter { title(key: $0) != nil } }

    struct Choice: Equatable {
        let id: TrackID
        let name: String
        /// The words of all transcripts on the track.
        let words: Int
    }

    let tracks: [Choice]
    /// The offered models whose file is in the model folder.
    let onDisk: Set<WhisperModel>
    var track: TrackID
    var language: WhisperLanguage
    var model = WhisperModel.base

    /// Nil with no track. `selected` is the first track when it is nil or not in `tracks`.
    init?(tracks: [Choice], selected: TrackID?, onDisk: Set<WhisperModel>, language: WhisperLanguage) {
        guard let first = tracks.first else { return nil }
        self.tracks = tracks
        self.onDisk = onDisk
        self.language = language
        track = tracks.contains { $0.id == selected } ? selected ?? first.id : first.id
    }

    var words: Int { tracks.first { $0.id == track }?.words ?? 0 }
    var needsDownload: Bool { !onDisk.contains(model) }

    /// The default button: the download comes first, then Replace for a track with words.
    var buttonTitle: L10n {
        if needsDownload { return .sheetTranscribeDownload }
        return words > 0 ? .sheetTranscribeReplace : .sheetTranscribeStart
    }

    var request: TranscribeRequest {
        TranscribeRequest(
            track: track, trackName: tracks.first { $0.id == track }?.name ?? track.rawValue, language: language,
            model: model)
    }

    /// The size of the model file in the units of the Finder, from the catalog byte count.
    static func size(of model: WhisperModel, locale: Locale = .current) -> String {
        Int64(model.byteCount).formatted(.byteCount(style: .file).locale(locale))
    }

    /// The title format of a model in the pop-up. A new catalog model needs a case here and a string.
    /// Nil: the model is for the tests only.
    private static func title(key model: WhisperModel) -> L10n? {
        switch model {
        case .base: .sheetTranscribeStandard
        case .smallQ51: .sheetTranscribeAccurate
        case .largeV3TurboQ50: .sheetTranscribeMostAccurate
        case .tinyQ51: nil
        }
    }

    /// "Standard - 148 MB", "More Accurate - 190.1 MB, slower", or "Most Accurate - 574 MB, slowest".
    /// `text` gives the table value of a key.
    static func title(
        of model: WhisperModel, locale: Locale = .current, text: (L10n) -> String = { $0.text }
    ) -> String {
        guard let key = title(key: model) else { return model.rawValue }
        return String(format: text(key), locale: locale, size(of: model, locale: locale))
    }

    func remember(in defaults: UserDefaults?) {
        defaults?.set(TranscribeLanguages.stored(language), forKey: Self.languageKey)
    }
}

/// The Language pop-up of the sheet (UI council C-3 and U21).
enum TranscribeLanguages {
    /// The whisper codes of the preferred languages of the user, in order, with no repeat.
    static func preferred(_ identifiers: [String], supported: [String] = WhisperLanguage.codes) -> [String] {
        var seen: [String] = []
        for identifier in identifiers {
            guard let code = Locale.Language(identifier: identifier).languageCode?.identifier,
                supported.contains(code), !seen.contains(code)
            else { continue }
            seen.append(code)
        }
        return seen
    }

    /// The first selection: the last choice, else the app language when whisper supports it, else
    /// Automatic. A wrong detection from silence or crosstalk costs a full rerun.
    static func first(stored: String?, appLanguage: String?, supported: [String] = WhisperLanguage.codes)
        -> WhisperLanguage
    {
        if stored == "auto" { return .automatic }
        if let stored, supported.contains(stored) { return .code(stored) }
        if let appLanguage, let code = Locale.Language(identifier: appLanguage).languageCode?.identifier,
            supported.contains(code)
        {
            return .code(code)
        }
        return .automatic
    }

    static func stored(_ language: WhisperLanguage) -> String {
        switch language {
        case .automatic: "auto"
        case .code(let code): code
        }
    }

    /// The name of a code in the language of the app, else the code.
    static func name(_ code: String, locale: Locale = .current) -> String {
        locale.localizedString(forLanguageCode: code) ?? code
    }

    /// All codes by name.
    static func byName(_ codes: [String], locale: Locale = .current) -> [String] {
        codes.sorted {
            name($0, locale: locale).localizedStandardCompare(name($1, locale: locale)) == .orderedAscending
        }
    }
}

/// Tools > Transcribe Track... (decision 0065): the track, the language, the model, and the notes.
/// Return is the default button, Escape is Cancel.
struct TranscribeSheet: View {
    let model: SessionWindow
    @State private var draft: TranscribeDraft

    init(model: SessionWindow, draft: TranscribeDraft) {
        self.model = model
        _draft = State(initialValue: draft)
    }

    private var preferred: [String] { TranscribeLanguages.preferred(Locale.preferredLanguages) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.sheetTranscribeTitle.key).font(.headline)
            Form {
                Picker(L10n.sheetTranscribeTrack.key, selection: $draft.track) {
                    ForEach(draft.tracks, id: \.id) { Text(verbatim: $0.name).tag($0.id) }
                }
                Picker(L10n.sheetTranscribeLanguage.key, selection: $draft.language) {
                    Text(L10n.sheetTranscribeAutomatic.key).tag(WhisperLanguage.automatic)
                    ForEach(preferred, id: \.self) { code in
                        Text(verbatim: TranscribeLanguages.name(code)).tag(WhisperLanguage.code(code))
                    }
                    Divider()
                    ForEach(TranscribeLanguages.byName(WhisperLanguage.codes), id: \.self) { code in
                        Text(verbatim: TranscribeLanguages.name(code)).tag(WhisperLanguage.code(code))
                    }
                }
                Picker(L10n.sheetTranscribeModel.key, selection: $draft.model) {
                    ForEach(TranscribeDraft.models, id: \.self) {
                        Text(verbatim: TranscribeDraft.title(of: $0)).tag($0)
                    }
                }
            }
            .formStyle(.columns)
            if draft.words > 0 { note(replaceNote) }
            if draft.needsDownload { note(L10n.sheetTranscribeNoteDownload.text) }
            HStack {
                Spacer()
                Button(L10n.alertCancel.key) { model.cancelTranscribeSheet() }.keyboardShortcut(.cancelAction)
                Button(draft.buttonTitle.key) { model.startTranscribe(draft) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var replaceNote: String {
        draft.words == 1
            ? L10n.sheetTranscribeNoteReplaceOne.text : L10n.sheetTranscribeNoteReplaceMany.format(draft.words)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
