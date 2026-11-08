import Foundation

/// The ride lists of `<rides>` (leveler C20), by ID, from `rideSessionVersion` on.
struct RideLists {
    private var lists: [String: GainEnvelope] = [:]
    private var named: Set<String> = []

    init(_ root: XMLElement, version: Int) throws(SessionFileError) {
        let elements = root.sessionElements("rides")
        guard elements.count <= 1 else { throw .invalidValue(element: "rides", attribute: "count") }
        guard let element = elements.first else { return }
        guard version >= rideSessionVersion else { throw .invalidValue(element: "rides", attribute: "version") }
        for node in element.sessionElements("ride") {
            let id = try node.string("id")
            guard lists[id] == nil else { throw .invalidValue(element: "ride", attribute: "id") }
            var text = node.stringValue ?? ""
            guard let points = text.withUTF8(Self.scan) else { throw .invalidValue(element: "ride", attribute: "text") }
            lists[id] = GainEnvelope(valid: points)
        }
    }

    /// The list that the `ride` attribute of a clip names, or `.empty` with no attribute.
    mutating func ride(of clip: XMLElement, version: Int) throws(SessionFileError) -> GainEnvelope {
        guard let id = clip.attribute(forName: "ride")?.stringValue else { return .empty }
        guard version >= rideSessionVersion, let list = lists[id] else {
            throw .invalidValue(element: "clip", attribute: "ride")
        }
        named.insert(id)
        return list
    }

    /// Throws for a list that no clip names.
    func checkAllNamed() throws(SessionFileError) {
        guard named.count == lists.count else { throw .invalidValue(element: "ride", attribute: "id") }
    }

    /// The points of a list: `<frame> <gain>` pairs with one space between numbers (C20). A frame is
    /// `[0-9]+` up to `Frames.limit`, and the frames ascend strictly. A gain is 32 bytes or fewer of
    /// `-?[0-9]+(\.[0-9]+)?(e[-+][0-9]+)?` and finite; it clamps to `Gain.range`. Nil for any other
    /// text. A gain with no exponent, 2 decimals or fewer, and 6 digits or fewer is its digits over
    /// 100: one division of two exact values, so it equals `Double` of the text.
    static func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> [GainEnvelope.Point]? {
        let (space, minus, plus, dot, exponent): (UInt8, UInt8, UInt8, UInt8, UInt8) = (32, 45, 43, 46, 101)
        func digit(_ index: Int) -> Int? {
            guard index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 else { return nil }
            return Int(bytes[index] - 48)
        }
        guard !bytes.isEmpty else { return nil }
        var points: [GainEnvelope.Point] = []
        points.reserveCapacity(bytes.count / 15)
        var index = 0
        while true {
            var frame = 0
            let frameStart = index
            while let value = digit(index) {
                frame = frame * 10 + value
                guard frame <= Frames.limit.count else { return nil }
                index += 1
            }
            guard index > frameStart, index < bytes.count, bytes[index] == space else { return nil }
            index += 1
            let start = index
            if index < bytes.count, bytes[index] == minus { index += 1 }
            var (whole, digits, decimals, isExponent) = (0, 0, 0, false)
            while let value = digit(index) {
                if digits < 7 { whole = whole * 10 + value }
                (digits, index) = (digits + 1, index + 1)
            }
            guard digits > 0 else { return nil }
            if index < bytes.count, bytes[index] == dot {
                index += 1
                while let value = digit(index) {
                    if digits < 7 { whole = whole * 10 + value }
                    (digits, decimals, index) = (digits + 1, decimals + 1, index + 1)
                }
                guard decimals > 0 else { return nil }
            }
            if index < bytes.count, bytes[index] == exponent {
                isExponent = true
                index += 1
                guard index < bytes.count, bytes[index] == minus || bytes[index] == plus else { return nil }
                index += 1
                let exponentStart = index
                while digit(index) != nil { index += 1 }
                guard index > exponentStart else { return nil }
            }
            guard index == bytes.count || bytes[index] == space, index - start <= 32 else { return nil }
            let dB: Double
            if !isExponent, decimals <= 2, digits <= 6 {
                let hundredths = whole * [100, 10, 1][decimals]
                dB = Double(bytes[start] == minus ? -hundredths : hundredths) / 100
            } else {
                let token = Substring(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
                guard let value = Double(token) else { return nil }
                dB = value
            }
            guard dB.isFinite, points.last.map({ $0.frame.count < frame }) ?? true else { return nil }
            points.append(GainEnvelope.Point(frame: Frames(frame), gain: Gain(clamping: dB)!))
            if index == bytes.count { return points }
            index += 1
            guard index < bytes.count else { return nil }
        }
    }
}
