import AppKit
import DirigibleAudio
import Foundation

/// An entry of the Model pop-up of the Transcribe sheet (UI council U15, U16).
enum ModelEntry: Hashable {
    case catalog(WhisperModel)
    /// The kept model file of the user.
    case file
    /// Choose Model File...: the pop-up shows it while the open panel and the check run.
    case choose

    /// The value of the model memory of a language choice (U21).
    var stored: String? {
        switch self {
        case .catalog(let model): model.rawValue
        case .file: "file"
        case .choose: nil
        }
    }
}

/// The byte count and the modification date of a file.
struct FileStatus: Equatable, Sendable {
    let byteCount: Int
    let modified: Date

    /// Nil when the file is missing or is no regular file. It reads only the file status.
    init?(of url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let size = values.fileSize, let date = values.contentModificationDate
        else { return nil }
        (byteCount, modified) = (size, date)
    }

    init(byteCount: Int, modified: Date) { (self.byteCount, self.modified) = (byteCount, modified) }

    /// `init(of:)` off the main actor.
    static func read(_ url: URL) async -> FileStatus? { await Task.detached { FileStatus(of: url) }.value }
}

/// The model file of the user that the app keeps in its defaults (decision 0065 D8, U16, C18):
/// the path, the file status at the last check, and the record of the last passed check. A
/// matching SHA-256 proves the facts of the record, so the sheet does not parse the file.
struct KeptModelFile: Codable, Equatable {
    static let key = "transcribe.modelFile"

    let path: String
    var byteCount: Int
    var modified: Date
    /// Nil after a change of the file at the sheet open: the next job runs the helper.
    var passed: PassedModelFile?

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var status: FileStatus { FileStatus(byteCount: byteCount, modified: modified) }

    init(url: URL, status: FileStatus, passed: PassedModelFile?) {
        (path, byteCount, modified, self.passed) = (url.path, status.byteCount, status.modified, passed)
    }

    static func load(from defaults: UserDefaults?) -> KeptModelFile? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeptModelFile.self, from: data)
    }

    func store(in defaults: UserDefaults?) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.key)
    }

    /// "ggml-medium.bin - 1.5 GB" in the units of the Finder, or "ggml-medium.bin (missing)".
    func title(missing: Bool, locale: Locale = .current) -> String {
        if missing { return L10n.sheetTranscribeMissing.format(name) }
        return "\(name) - \(Int64(byteCount).formatted(.byteCount(style: .file).locale(locale)))"
    }
}

/// The line of the sheet check in the place of the notes (U17).
enum ModelCheckLine: Equatable {
    /// A file of more than `waitBytes` bytes adds the wait line.
    static let waitBytes = 500_000_000

    case running(name: String, byteCount: Int)
    case passed(WhisperModelFacts)
    /// The refusal text, in the label color with a warning symbol.
    case refused(String)

    var text: String {
        switch self {
        case .running(let name, let byteCount):
            L10n.sheetTranscribeCheckRunning.format(name)
                + (byteCount > Self.waitBytes ? " " + L10n.sheetTranscribeCheckWait.text : "")
        case .passed(let facts): Self.text(of: facts)
        case .refused(let text): text
        }
    }

    /// "Medium, multilingual" or "Tiny, English only": the kind is the OpenAI model name.
    static func text(of facts: WhisperModelFacts) -> String {
        let kind =
            switch facts.kind {
            case .tiny: "Tiny"
            case .base: "Base"
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            case nil: L10n.sheetTranscribeCheckLayers.format(facts.audioLayers)
            }
        return (facts.isMultilingual ? L10n.sheetTranscribeCheckMultilingual : .sheetTranscribeCheckEnglish)
            .format(kind)
    }
}

/// The model memory of the sheet (U21): the model of the last started job for each language
/// choice, Automatic as one choice. Only a job start writes it.
enum TranscribeModelMemory {
    static func key(_ language: WhisperLanguage) -> String {
        "transcribe.model.\(TranscribeLanguages.stored(language))"
    }

    static func entry(for language: WhisperLanguage, in defaults: UserDefaults?) -> ModelEntry? {
        switch defaults?.string(forKey: key(language)) {
        case "file": .file
        case let stored?: WhisperModel(rawValue: stored).map { .catalog($0) }
        case nil: nil
        }
    }

    static func remember(_ entry: ModelEntry, for language: WhisperLanguage, in defaults: UserDefaults?) {
        guard let stored = entry.stored else { return }
        defaults?.set(stored, forKey: key(language))
    }
}

extension TranscribeState {
    /// The open panel of Choose Model File... and Locate...: any file, one file, no folder. A
    /// ggml file is ".bin" with no content type, and the parse refuses a wrong file (U15).
    static func modelPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        return panel
    }

    /// The live open panel: the picked file, else nil for Cancel.
    static func livePickModelFile() async -> URL? {
        let panel = modelPanel()
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url : nil
    }
}
