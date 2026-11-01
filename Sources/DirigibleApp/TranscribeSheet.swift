import DirigibleAudio
import DirigibleCore
import SwiftUI

/// What a transcription job needs. The window keeps it for Transcribe Again.
struct TranscribeRequest: Hashable {
    let track: TrackID
    let trackName: String
    let language: WhisperLanguage
    let model: WhisperModelChoice
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
    var model: ModelEntry
    /// The model file of the user that the app keeps, and whether it was missing at the sheet open.
    var kept: KeptModelFile?
    var keptMissing = false
    /// The line of a sheet check, in the place of the notes.
    var check: ModelCheckLine?
    /// The language before an English-only file took the pop-up (C26); nil while the pop-up is on.
    var languageBeforeFile: WhisperLanguage?
    /// The entry before Choose Model File..., while the open panel and the check run.
    var beforeChoice: ModelEntry?

    /// Nil with no track. `selected` is the first track when it is nil or not in `tracks`. The
    /// model is `remembered`, the model of the last job for `language` (U21), else the model of
    /// `languageModel(_:)`.
    init?(
        tracks: [Choice], selected: TrackID?, onDisk: Set<WhisperModel>, language: WhisperLanguage,
        kept: KeptModelFile? = nil, remembered: ModelEntry? = nil
    ) {
        guard let first = tracks.first else { return nil }
        self.tracks = tracks
        self.onDisk = onDisk
        self.language = language
        self.kept = kept
        model = .catalog(Self.languageModel(language))
        track = tracks.contains { $0.id == selected } ? selected ?? first.id : first.id
        if let remembered, remembered != .file || kept != nil { select(remembered) }
    }

    /// The model of a language choice with no job yet. Spanish starts at More Accurate: in the C27
    /// probe it made fewer errors than Standard, at 0.7 times the clip length on an Intel Mac.
    /// Other languages start at Standard.
    static func languageModel(_ language: WhisperLanguage) -> WhisperModel {
        language == .code("es") ? .smallQ51 : .base
    }

    var words: Int { tracks.first { $0.id == track }?.words ?? 0 }
    var needsDownload: Bool {
        guard case .catalog(let model) = model else { return false }
        return !onDisk.contains(model)
    }
    var isChecking: Bool { if case .running = check { true } else { false } }
    var canStart: Bool { model != .choose && !isChecking && !(model == .file && keptMissing) }
    /// Off while an English-only file is selected (C26).
    var languageLocked: Bool { languageBeforeFile != nil }

    /// Selects `entry`. An English-only file sets the language to English and locks it; another
    /// entry gives back the language before the file.
    mutating func select(_ entry: ModelEntry) {
        if entry == .file, kept?.passed?.facts.isMultilingual == false {
            if languageBeforeFile == nil { languageBeforeFile = language }
            language = .code("en")
        } else if entry != .choose, let before = languageBeforeFile {
            language = before
            languageBeforeFile = nil
        }
        model = entry
    }

    /// The kept file is missing at the sheet open: a selection of it gives the language rule.
    mutating func keptFileIsMissing() {
        keptMissing = true
        if model == .file { select(.catalog(Self.languageModel(languageBeforeFile ?? language))) }
    }

    /// The entries of the Model pop-up, nil for a divider (U16): the catalog models, the kept
    /// file, and Choose Model File....
    var entries: [ModelEntry?] {
        Self.models.map { .catalog($0) } + (kept == nil ? [] : [nil, .file]) + [nil, .choose]
    }

    /// The notes under the pop-ups; none while a check line shows. A kept file gives the facts of
    /// its record and the note of a model that is not from the list.
    var notes: [String] {
        guard check == nil else { return [] }
        var notes: [String] = []
        if words > 0 {
            notes.append(
                words == 1
                    ? L10n.sheetTranscribeNoteReplaceOne.text : L10n.sheetTranscribeNoteReplaceMany.format(words))
        }
        if needsDownload { notes.append(L10n.sheetTranscribeNoteDownload.text) }
        if model == .file {
            if let facts = kept?.passed?.facts { notes.append(ModelCheckLine.text(of: facts)) }
            notes.append(L10n.sheetTranscribeNoteFile.text)
        }
        return notes
    }

    /// The default button: the download comes first, then Replace for a track with words.
    var buttonTitle: L10n {
        if needsDownload { return .sheetTranscribeDownload }
        return words > 0 ? .sheetTranscribeReplace : .sheetTranscribeStart
    }

    var request: TranscribeRequest {
        let choice: WhisperModelChoice =
            switch model {
            case .catalog(let model): .catalog(model)
            case .file: kept.map { .file($0.url, passed: $0.passed) } ?? .catalog(Self.languageModel(language))
            case .choose: .catalog(Self.languageModel(language))
            }
        return TranscribeRequest(
            track: track, trackName: tracks.first { $0.id == track }?.name ?? track.rawValue, language: language,
            model: choice)
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

    /// Keeps the language choice and the model memory of that choice (U21). The choice is the
    /// language before an English-only file.
    func remember(in defaults: UserDefaults?) {
        let choice = languageBeforeFile ?? language
        defaults?.set(TranscribeLanguages.stored(choice), forKey: Self.languageKey)
        TranscribeModelMemory.remember(model, for: choice, in: defaults)
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
/// Return is the default button, Escape is Cancel. The values are the draft of the window, which
/// the window changes after the open panel and the check of a model file.
struct TranscribeSheet: View {
    let model: SessionWindow

    private var preferred: [String] { TranscribeLanguages.preferred(Locale.preferredLanguages) }

    var body: some View {
        if let draft = model.transcribe.draft { content(draft) }
    }

    private func content(_ draft: TranscribeDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.sheetTranscribeTitle.key).font(.headline)
            Form {
                Picker(L10n.sheetTranscribeTrack.key, selection: binding(\.track, draft.track)) {
                    ForEach(draft.tracks, id: \.id) { Text(verbatim: $0.name).tag($0.id) }
                }
                Picker(L10n.sheetTranscribeLanguage.key, selection: binding(\.language, draft.language)) {
                    Text(L10n.sheetTranscribeAutomatic.key).tag(WhisperLanguage.automatic)
                    ForEach(preferred, id: \.self) { code in
                        Text(verbatim: TranscribeLanguages.name(code)).tag(WhisperLanguage.code(code))
                    }
                    Divider()
                    ForEach(TranscribeLanguages.byName(WhisperLanguage.codes), id: \.self) { code in
                        Text(verbatim: TranscribeLanguages.name(code)).tag(WhisperLanguage.code(code))
                    }
                }
                .disabled(draft.languageLocked)
                Picker(
                    L10n.sheetTranscribeModel.key,
                    selection: Binding(
                        get: { model.transcribe.draft?.model ?? draft.model }, set: { model.selectModel($0) })
                ) {
                    ForEach(Array(draft.entries.enumerated()), id: \.offset) { _, entry in
                        switch entry {
                        case .catalog(let model)?:
                            Text(verbatim: TranscribeDraft.title(of: model)).tag(ModelEntry.catalog(model))
                        case .file?:
                            Text(verbatim: draft.kept?.title(missing: draft.keptMissing) ?? "").tag(ModelEntry.file)
                                .help(draft.kept?.path ?? "")
                        case .choose?: Text(L10n.sheetTranscribeChoose.key).tag(ModelEntry.choose)
                        case nil: Divider()
                        }
                    }
                }
            }
            .formStyle(.columns)
            if let check = draft.check { checkLine(check) }
            ForEach(draft.notes, id: \.self) { note($0) }
            HStack {
                Spacer()
                Button(L10n.alertCancel.key) { model.cancelTranscribeSheet() }.keyboardShortcut(.cancelAction)
                Button(draft.buttonTitle.key) { model.startTranscribe(draft) }.keyboardShortcut(.defaultAction)
                    .disabled(!draft.canStart)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func binding<Value>(_ path: WritableKeyPath<TranscribeDraft, Value>, _ shown: Value) -> Binding<Value> {
        Binding(
            get: { model.transcribe.draft?[keyPath: path] ?? shown },
            set: { model.transcribe.draft?[keyPath: path] = $0 })
    }

    /// The check line (U17): a running check with a small spinner, a pass with the facts, or a
    /// refusal with a warning symbol in the label color. The text is selectable.
    @ViewBuilder private func checkLine(_ line: ModelCheckLine) -> some View {
        switch line {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                note(line.text)
            }
        case .passed: note(line.text)
        case .refused:
            Label {
                Text(verbatim: line.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
