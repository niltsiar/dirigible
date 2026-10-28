import DirigibleCore

extension SessionView {
    /// The origin of a rendered file (decision 0057): the direct source, the source frame of its
    /// first frame, the gain that the render added to its clips, and the effects as rendered.
    struct OriginView: Encodable {
        struct EffectView: Encodable {
            /// "hum" or "noise".
            let kind: String
            /// The mains frequency of a hum.
            var hz: Int?
            /// The reduction of a noise.
            var decibels: Int?
        }

        let source: String
        let offset: Int
        let addedGain: Double
        let effects: [EffectView]

        init(_ origin: RenderOrigin) {
            source = origin.source.rawValue
            offset = origin.offset.count
            addedGain = origin.addedGain.dB
            effects = origin.treatment.effects.map { effect in
                switch effect {
                case .hum(let hertz): EffectView(kind: "hum", hz: hertz.rawValue)
                case .noise(let reduction): EffectView(kind: "noise", decibels: reduction.decibels)
                }
            }
        }
    }
}

/// The origin of `file` in the `info` text, or an empty text for a file with no origin.
func originText(of file: AudioFile) -> String {
    guard let origin = file.origin else { return "" }
    let effects = origin.treatment.effects.map { effect in
        switch effect {
        case .hum(let hertz): "hum \(hertz.rawValue) Hz"
        case .noise(let reduction): "noise \(reduction.decibels) dB"
        }
    }
    return " origin \(origin.source) offset \(origin.offset) added gain \(origin.addedGain) "
        + effects.joined(separator: ", ")
}
