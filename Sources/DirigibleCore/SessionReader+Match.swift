import Foundation

extension VoiceMatch {
    /// `<match amount reference curve target>` with an optional `bypassed` (decision 0074 D4), from
    /// `matchSessionVersion` on. A list is numbers with one space between them. The checked init owns
    /// each range, and its refusal names the attribute.
    init(_ node: XMLElement, version: Int) throws(SessionFileError) {
        guard version >= matchSessionVersion else { throw .invalidValue(element: "match", attribute: "version") }
        guard let amount = Amount(try node.value("amount")) else {
            throw .invalidValue(element: "match", attribute: "amount")
        }
        func numbers(_ attribute: String) throws(SessionFileError) -> [Double] {
            let parts = try node.string(attribute).split(separator: " ", omittingEmptySubsequences: false)
            let values = parts.compactMap { Double($0) }
            guard values.count == parts.count else { throw .invalidValue(element: "match", attribute: attribute) }
            return values
        }
        let (reference, curve, target) = (try node.string("reference"), try numbers("curve"), try numbers("target"))
        let isBypassed = try node.flag("bypassed", since: matchSessionVersion, version: version)
        do throws(Field) {
            try self.init(
                amount: amount, isBypassed: isBypassed, reference: reference, curve: curve, targetPowers: target)
        } catch {
            throw .invalidValue(element: "match", attribute: error.rawValue)
        }
    }
}
