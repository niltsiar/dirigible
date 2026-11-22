import Foundation

extension ExportPreset {
    /// The presets of `<exportPresets>` (decision 0080), from `presetSessionVersion` on, in file
    /// order. Empty with no element. Of two presets with one exact name, only the first stays.
    static func list(in root: XMLElement, version: Int) throws(SessionFileError) -> [ExportPreset] {
        guard let list = root.sessionElements("exportPresets").first else { return [] }
        guard version >= presetSessionVersion else {
            throw .invalidValue(element: "exportPresets", attribute: "version")
        }
        var presets: [ExportPreset] = []
        var names: Set<PresetName> = []
        for node in list.sessionElements("preset") {
            let preset = try ExportPreset(node)
            if names.insert(preset.name).inserted { presets.append(preset) }
        }
        return presets
    }

    /// `<preset name format bits bitRate channels rate loudness>`: `bits` only with `wav` and `flac`,
    /// `bitRate` only with `aac` and `mp3`, and an absent `loudness` is Off. Each value outside its
    /// list refuses the file with its attribute; these rules do not widen in a later build. The name
    /// gets only the non-empty and storable rules, and is never checked against a built-in or another
    /// name, so a stored name always reads back.
    init(_ node: XMLElement) throws(SessionFileError) {
        func invalid(_ attribute: String) -> SessionFileError { .invalidValue(element: "preset", attribute: attribute) }
        func absent(_ attribute: String) throws(SessionFileError) {
            if node.attribute(forName: attribute) != nil { throw invalid(attribute) }
        }
        let format: ExportFormat
        switch try node.string("format") {
        case let token where ["wav", "flac"].contains(token):
            try absent("bitRate")
            guard let bits = BitDepth(rawValue: try node.value("bits")) else { throw invalid("bits") }
            format = token == "wav" ? .wav(bits) : .flac(bits)
        case let token where ["aac", "mp3"].contains(token):
            try absent("bits")
            guard let rate = BitRate(rawValue: try node.value("bitRate")) else { throw invalid("bitRate") }
            format = token == "aac" ? .aac(rate) : .mp3(rate)
        default: throw invalid("format")
        }
        guard let layout = ChannelLayout(rawValue: try node.string("channels")) else { throw invalid("channels") }
        let rateToken = try node.string("rate")
        guard let rate = ExportRate.allCases.first(where: { $0.fileToken == rateToken }) else { throw invalid("rate") }
        var loudness: LoudnessTarget?
        if let token = node.attribute(forName: "loudness")?.stringValue {
            guard let target = LoudnessTarget(rawValue: token) else { throw invalid("loudness") }
            loudness = target
        }
        let text = try node.string("name")
        guard let name = PresetName(stored: text) else { throw invalid("name") }
        // A file format of `wav`, `flac`, `aac`, or `mp3` is never `.floatCAF`, the one refusal.
        self.init(
            name: name, options: try! PresetOptions(format: format, layout: layout, rate: rate, loudness: loudness))
    }
}

extension ExportFormat {
    /// The `format` token of `<preset>`. No preset writes `caf`: `PresetOptions` refuses `.floatCAF`.
    var fileToken: String {
        switch self {
        case .wav: "wav"
        case .flac: "flac"
        case .aac: "aac"
        case .mp3: "mp3"
        case .floatCAF: "caf"
        }
    }
}

extension ExportRate {
    /// The `rate` token of `<preset>`.
    var fileToken: String {
        switch self {
        case .session: "session"
        case .hz44100: "44100"
        case .hz48000: "48000"
        }
    }
}
