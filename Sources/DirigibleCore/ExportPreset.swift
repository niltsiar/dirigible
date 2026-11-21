import Foundation

/// The export options of a preset (decision 0080). `.floatCAF`, the format of `dirigible render`,
/// is refused.
public struct PresetOptions: Hashable, Sendable {
    public let format: ExportFormat
    public let layout: ChannelLayout
    public let rate: ExportRate
    /// Nil: no gain and no limiter.
    public let loudness: LoudnessTarget?

    public init(format: ExportFormat, layout: ChannelLayout, rate: ExportRate, loudness: LoudnessTarget?)
        throws(SessionError)
    {
        if case .floatCAF = format { throw .invalidPreset }
        self.format = format
        self.layout = layout
        self.rate = rate
        self.loudness = loudness
    }
}

/// 1 to `maximumLength` characters that the session can store, with no space at either end and no
/// control character. It keeps the exact text, and `==` compares the exact text, so a case-only
/// rename changes the session.
public struct PresetName: Hashable, Sendable {
    public static let maximumLength = 64
    public let text: String

    public init(_ text: String) throws(SessionError) {
        guard (1...Self.maximumLength).contains(text.count), text.first?.isWhitespace == false,
            text.last?.isWhitespace == false,
            text.unicodeScalars.allSatisfy({ $0.isStorableInSession && $0.properties.generalCategory != .control })
        else { throw .invalidPresetName(text) }
        self.text = text
    }

    /// The one key of the collision rule and of the lookup: the case-folded text.
    public var key: String { Self.key(of: text) }

    static func key(of text: String) -> String { text.folding(options: .caseInsensitive, locale: nil) }
}

/// A built-in preset: a constant of the code, never stored in a file. The raw value is the stored
/// ID: the CLI and tool token, and the name in a file name. The app shows a localized display name.
public enum BuiltInPreset: String, CaseIterable, Hashable, Sendable {
    case master, podcast

    public var options: PresetOptions {
        switch self {
        // A pass-through: the samples of the mix.
        case .master: try! PresetOptions(format: .wav(.bits24), layout: .stereo, rate: .session, loudness: nil)
        // The podcast target of decision 0008 is -19 LUFS for mono.
        case .podcast: try! PresetOptions(format: .mp3(.k128), layout: .mono, rate: .hz44100, loudness: .podcast)
        }
    }
}

/// A preset of the list: a built-in or a session preset.
public enum PresetRef: Hashable, Sendable {
    case builtIn(BuiltInPreset)
    case session(PresetName)
}

public struct ExportPreset: Hashable, Sendable {
    public let name: PresetName
    public let options: PresetOptions

    public init(name: PresetName, options: PresetOptions) {
        self.name = name
        self.options = options
    }
}

extension Session {
    /// Adds the preset at the end, or puts it in the place of the preset named `replacing`. On an
    /// add, or a rename to another key, it throws `.presetNameTaken` when the key of the name is the
    /// key of another entry of `allExportPresets`, a built-in ID included. An edit under its own key
    /// has no collision check, so a stored preset that a later built-in shadows can change.
    public mutating func setExportPreset(_ preset: ExportPreset, replacing: PresetName? = nil) throws(SessionError) {
        let index = try replacing.map { name throws(SessionError) in try exportPresetIndex(name) }
        if replacing?.key != preset.name.key {
            let keys =
                BuiltInPreset.allCases.map { PresetName.key(of: $0.rawValue) }
                + exportPresets.indices.filter { $0 != index }.map { exportPresets[$0].name.key }
            guard !keys.contains(preset.name.key) else { throw .presetNameTaken(preset.name.text) }
        }
        if let index { exportPresets[index] = preset } else { exportPresets.append(preset) }
    }

    public mutating func removeExportPreset(_ name: PresetName) throws(SessionError) {
        exportPresets.remove(at: try exportPresetIndex(name))
    }

    /// The built-in presets, then the session presets: the list of the app, the CLI, and the tools.
    public var allExportPresets: [(ref: PresetRef, options: PresetOptions)] {
        BuiltInPreset.allCases.map { (.builtIn($0), $0.options) }
            + exportPresets.map { (.session($0.name), $0.options) }
    }

    /// The first preset whose key is the key of `text`, with the session presets before the
    /// built-ins: a stored name keeps its meaning when a later build adds a built-in of its key.
    public func exportPreset(named text: String) -> (ref: PresetRef, options: PresetOptions)? {
        let key = PresetName.key(of: text)
        if let preset = exportPresets.first(where: { $0.name.key == key }) {
            return (.session(preset.name), preset.options)
        }
        return BuiltInPreset.allCases.first { PresetName.key(of: $0.rawValue) == key }.map {
            (.builtIn($0), $0.options)
        }
    }

    private func exportPresetIndex(_ name: PresetName) throws(SessionError) -> Int {
        guard let index = exportPresets.firstIndex(where: { $0.name == name }) else { throw .unknownPreset(name.text) }
        return index
    }
}
