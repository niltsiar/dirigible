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
            format = options.format.fileToken
            switch options.format {
            case .wav(let depth), .flac(let depth): (bits, bitRate) = (depth.rawValue, nil)
            case .aac(let kbits), .mp3(let kbits): (bits, bitRate) = (nil, kbits.rawValue)
            case .floatCAF: preconditionFailure("PresetOptions refuses .floatCAF")
            }
            channels = options.layout.rawValue
            rate = options.rate.fileToken
            loudness = options.loudness?.rawValue
        }
    }
}
