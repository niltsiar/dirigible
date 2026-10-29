import Foundation

extension RenderOrigin {
    /// `<origin source offset gain>` from version 12 on (decision 0057 D9), with one element for
    /// each effect: `<hum hz>` from version 13 on, 50 or 60, `<noise decibels>`, and from version 14
    /// on `<declip percent>`, `<rumble hz>`, and `<deess hz decibels>` (decision 0064 D7). It refuses
    /// an unknown element, a value outside its type, no effect, and a repeated kind.
    init(_ node: XMLElement, version: Int) throws(SessionFileError) {
        guard version >= 12 else { throw .invalidValue(element: "origin", attribute: "version") }
        var effects: [Effect] = []
        for case let child as XMLElement in node.children ?? [] {
            guard child.uri == sessionNamespace else {
                throw .invalidValue(element: child.localName ?? "", attribute: "namespace")
            }
            switch child.localName {
            case "hum":
                guard version >= 13 else { throw .invalidValue(element: "hum", attribute: "version") }
                guard let hertz = Hum(rawValue: try child.value("hz")) else {
                    throw .invalidValue(element: "hum", attribute: "hz")
                }
                effects.append(.hum(hertz))
            case "noise":
                guard let amount = NoiseReduction(decibels: try child.value("decibels")) else {
                    throw .invalidValue(element: "noise", attribute: "decibels")
                }
                effects.append(.noise(amount))
            case "declip":
                guard version >= 14 else { throw .invalidValue(element: "declip", attribute: "version") }
                guard let declip = Declip(percent: try child.value("percent")) else {
                    throw .invalidValue(element: "declip", attribute: "percent")
                }
                effects.append(.declip(declip))
            case "rumble":
                guard version >= 14 else { throw .invalidValue(element: "rumble", attribute: "version") }
                guard let rumble = Rumble(hertz: try child.value("hz")) else {
                    throw .invalidValue(element: "rumble", attribute: "hz")
                }
                effects.append(.rumble(rumble))
            case "deess":
                guard version >= 14 else { throw .invalidValue(element: "deess", attribute: "version") }
                let (hertz, decibels): (Int, Int) = (try child.value("hz"), try child.value("decibels"))
                guard DeEss.hertzRange.contains(hertz) else { throw .invalidValue(element: "deess", attribute: "hz") }
                guard let deess = DeEss(hertz: hertz, decibels: decibels) else {
                    throw .invalidValue(element: "deess", attribute: "decibels")
                }
                effects.append(.deess(deess))
            default: throw .invalidValue(element: child.localName ?? "", attribute: "element")
            }
        }
        guard let treatment = Treatment(effects) else { throw .invalidValue(element: "origin", attribute: "effects") }
        guard let gain = Gain(dB: try node.value("gain")) else {
            throw .invalidValue(element: "origin", attribute: "gain")
        }
        self.init(
            source: FileID(try node.string("source")), offset: try node.frames("offset"), treatment: treatment,
            addedGain: gain)
    }
}
