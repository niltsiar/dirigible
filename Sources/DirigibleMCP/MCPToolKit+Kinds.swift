import DirigibleCore
import Foundation

/// The JSON type of an argument: its schema, the text of a value of a wrong type, and its parse.
/// `parse` gives nil for a wrong value.
struct Kind<T: Sendable>: Sendable {
    let schema: Schema
    let expected: String
    let parse: @Sendable (Any) -> T?
}

extension Kind where T == String {
    static let string = Kind(schema: ["type": "string"], expected: "a string") { $0 as? String }
}

extension Kind where T == Bool {
    static let boolean = Kind(schema: ["type": "boolean"], expected: "true or false") { value in
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }
}

extension Kind where T == Int {
    /// An exact integer in -2^53...2^53, so no sum in `Session` can pass `Int.max` (V23).
    static func integer(minimum: Int? = nil) -> Kind {
        var schema: Schema = ["type": "integer"]
        if let minimum { schema["minimum"] = minimum }
        let expected = minimum.map { "an integer, \($0) or more" } ?? "an integer"
        return Kind(schema: schema, expected: expected) { value in
            guard let number = exactInteger(value), number >= minimum ?? number else { return nil }
            return number
        }
    }
}

extension Kind where T == Gain {
    /// A number of dB in `Gain.range` (V9: `Gain(dB:)`).
    static let gain = Kind(
        schema: ["type": "number", "minimum": Gain.range.lowerBound, "maximum": Gain.range.upperBound],
        expected: "a number of dB \(Gain.rangeText)"
    ) { value in
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        return Gain(dB: number.doubleValue)
    }

    /// A level in dB under 0, as the schema gives it. The parse is that of `gain`, so the work
    /// refuses 0 and over with the text of its command.
    static let level = Kind(
        schema: ["type": "number", "minimum": Gain.range.lowerBound, "exclusiveMaximum": 0.0],
        expected: "a number of dB under 0, \(Int(Gain.range.lowerBound)) or more", parse: gain.parse)
}

extension Kind where T == NoiseReduction {
    /// A whole number of dB in `NoiseReduction.range`.
    static let reduction = Kind(
        schema: [
            "type": "integer", "minimum": NoiseReduction.range.lowerBound, "maximum": NoiseReduction.range.upperBound,
        ],
        expected: ClipRenderWork.reductionExpected
    ) { value in exactInteger(value).flatMap { NoiseReduction(decibels: $0) } }
}

extension Kind where T == Hum {
    /// 50 or 60 Hz.
    static let hum = Kind(
        schema: ["type": "integer", "enum": Hum.allCases.map(\.rawValue)], expected: ClipRenderWork.humExpected
    ) { value in exactInteger(value).flatMap { Hum(rawValue: $0) } }
}

extension Kind where T == [String] {
    static func strings(minItems: Int = 0) -> Kind {
        let schema: Schema = ["type": "array", "items": ["type": "string"], "minItems": minItems]
        let expected = minItems > 0 ? "an array of strings with one item or more" : "an array of strings"
        return Kind(schema: schema, expected: expected) { value in
            guard let strings = value as? [Any], strings.count >= minItems else { return nil }
            let parsed = strings.compactMap { $0 as? String }
            return parsed.count == strings.count ? parsed : nil
        }
    }
}

extension Kind where T == [Int] {
    static func integers(minItems: Int = 0) -> Kind {
        let schema: Schema = ["type": "array", "items": ["type": "integer"], "minItems": minItems]
        let expected = minItems > 0 ? "an array of integers with one item or more" : "an array of integers"
        return Kind(schema: schema, expected: expected) { value in
            guard let numbers = value as? [Any], numbers.count >= minItems else { return nil }
            let parsed = numbers.compactMap(exactInteger)
            return parsed.count == numbers.count ? parsed : nil
        }
    }
}

extension Kind where T == Route.Channels {
    /// One or two channel numbers (V7: `EditRules.channels`).
    static let channels = Kind(
        schema: ["type": "array", "items": ["type": "integer"], "minItems": 1, "maxItems": 2],
        expected: "an array of one or two channel numbers"
    ) { value in
        Kind<[Int]>.integers().parse(value).flatMap(EditRules.channels)
    }
}

extension Kind {
    /// One word of `words`, which `parse` turns into a value (layout, marker kind, edge).
    static func choice(_ words: [String], _ parse: @escaping @Sendable (String) -> T?) -> Kind {
        Kind(schema: ["type": "string", "enum": words], expected: words.joined(separator: " or ")) { value in
            (value as? String).flatMap(parse)
        }
    }
}

private func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

/// An exact JSON integer in -2^53...2^53. Not `true`, not 1.5, not "1".
func exactInteger(_ value: Any) -> Int? {
    guard let number = value as? NSNumber, !isBoolean(number), NSNumber(value: number.int64Value) == number,
        (-(1 << 53)...(1 << 53)).contains(number.int64Value)
    else { return nil }
    return Int(number.int64Value)
}
