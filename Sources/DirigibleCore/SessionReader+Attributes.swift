import Foundation

extension XMLElement {
    func children(_ list: String, _ name: String) -> [XMLElement] {
        sessionElements(list).first?.sessionElements(name) ?? []
    }

    /// Children by local name in the session namespace, so a prefixed file (`<d:tracks>`) reads too.
    func sessionElements(_ name: String) -> [XMLElement] {
        elements(forLocalName: name, uri: sessionNamespace)
    }

    func optionalString(_ attribute: String) -> String? {
        self.attribute(forName: attribute)?.stringValue
    }

    func string(_ attribute: String) throws(SessionFileError) -> String {
        guard let value = self.attribute(forName: attribute)?.stringValue else {
            throw .missingAttribute(element: localName ?? "", attribute: attribute)
        }
        return value
    }

    func value<T: LosslessStringConvertible>(_ attribute: String) throws(SessionFileError) -> T {
        guard let value = T(try string(attribute)) else { throw invalid(attribute) }
        return value
    }

    func frames(_ attribute: String) throws(SessionFileError) -> Frames {
        Frames(try value(attribute) as Int)
    }

    func gain(_ attribute: String) throws(SessionFileError) -> Gain {
        // An old file can hold a finite gain outside `Gain.range` (track fader run): it opens.
        guard let gain = Gain(clamping: try value(attribute)) else { throw invalid(attribute) }
        return gain
    }

    /// `fadeIn` and `fadeOut` from version 3 on (decision 0035). A missing one is 0. `Fades`
    /// refuses a negative value or a value over the limit.
    func fades(version: Int) throws(SessionFileError) -> Fades {
        func length(_ attribute: String) throws(SessionFileError) -> Frames {
            guard optionalString(attribute) != nil else { return .zero }
            guard version >= 3 else { throw invalid(attribute) }
            return try frames(attribute)
        }
        let fadeIn = try length("fadeIn")
        let fadeOut = try length("fadeOut")
        guard let fades = Fades(fadeIn: fadeIn, fadeOut: fadeOut) else {
            throw invalid(Fades(fadeIn: fadeIn, fadeOut: .zero) == nil ? "fadeIn" : "fadeOut")
        }
        return fades
    }

    /// `crossfadeIn` and `crossfadeOut` from version 4 on (decision 0036). A missing one is 0.
    /// `Crossfades` refuses an odd or negative value or a value over the limit. `ClipLane` checks
    /// the pairing.
    func crossfades(version: Int) throws(SessionFileError) -> Crossfades {
        func length(_ attribute: String) throws(SessionFileError) -> Frames {
            guard optionalString(attribute) != nil else { return .zero }
            guard version >= 4 else { throw invalid(attribute) }
            let value = try frames(attribute)
            guard Crossfades(start: value, end: .zero) != nil else { throw invalid(attribute) }
            return value
        }
        return Crossfades(start: try length("crossfadeIn"), end: try length("crossfadeOut"))!
    }

    /// `<envelope>` from version 10 on (decision 0060). A negative frame, a frame over the limit,
    /// frames that do not ascend strictly, and a gain that is not finite are invalid; a gain outside
    /// `Gain.range` clamps. `Session.check` refuses a point after the end of the file.
    func envelope(version: Int) throws(SessionFileError) -> GainEnvelope {
        guard let node = sessionElements("envelope").first else { return .empty }
        guard version >= 10 else { throw .invalidValue(element: "envelope", attribute: "version") }
        var points: [GainEnvelope.Point] = []
        for point in node.sessionElements("point") {
            let frame = try point.frames("frame")
            guard frame.isInRange, points.last.map({ $0.frame < frame }) ?? true else { throw point.invalid("frame") }
            points.append(GainEnvelope.Point(frame: frame, gain: try point.gain("gain")))
        }
        return GainEnvelope(valid: points)
    }

    /// A flag attribute from version `first` on: `muted` and `soloed` from 5 (decision 0039), `follow`
    /// from `followSessionVersion` (decision 0073), and `bypassed` of `<match>` from `matchSessionVersion`
    /// (decision 0074). The value is `true` or `false`; a missing one is false.
    func flag(_ attribute: String, since first: Int, version: Int) throws(SessionFileError) -> Bool {
        guard let value = optionalString(attribute) else { return false }
        guard version >= first, let flag = Bool(value) else { throw invalid(attribute) }
        return flag
    }

    private func invalid(_ attribute: String) -> SessionFileError {
        .invalidValue(element: localName ?? "", attribute: attribute)
    }
}
