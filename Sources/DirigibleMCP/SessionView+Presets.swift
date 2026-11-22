import DirigibleCore

extension SessionView {
    /// A session preset in the words of `<preset>` in `session.xml` (decision 0080): `bits` with wav and
    /// flac, `bitRate` with aac and mp3, and `rate` as `session`, `44100`, or `48000`. `loudness` is
    /// left out with no target.
    struct PresetView: Encodable {
        let name: String
        let format: String
        let bits: Int?
        let bitRate: Int?
        let channels: String
        let rate: String
        let loudness: String?

        init(_ preset: ExportPreset) {
            let options = preset.options
            name = preset.name.text
            switch options.format {
            case .wav(let depth): (format, bits, bitRate) = ("wav", depth.rawValue, nil)
            case .flac(let depth): (format, bits, bitRate) = ("flac", depth.rawValue, nil)
            case .aac(let kbits): (format, bits, bitRate) = ("aac", nil, kbits.rawValue)
            case .mp3(let kbits): (format, bits, bitRate) = ("mp3", nil, kbits.rawValue)
            case .floatCAF: preconditionFailure("PresetOptions refuses .floatCAF")
            }
            channels = options.layout.rawValue
            rate =
                switch options.rate {
                case .session: "session"
                case .hz44100: "44100"
                case .hz48000: "48000"
                }
            loudness = options.loudness?.rawValue
        }
    }
}
