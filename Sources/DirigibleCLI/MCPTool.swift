import DirigibleCore
import Foundation

/// The text of an MCP tool error result (`isError: true`).
struct ToolError: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// An edit of one tool call. It gives the new IDs, in the order that the command prints them.
/// `editPackage` and, in Release 3, `Studio.edit` run the same closure type.
typealias ToolEdit = @Sendable (inout Session) throws(SessionError) -> [String]

/// What a tool call does after its arguments are checked.
enum ToolWork: Sendable {
    /// A package edit under the lock. A `ripple` edit also refuses a split take.
    case edit(ripple: Bool = false, ToolEdit)
    /// `session_info`: no lock, as `dirigible info`. `range` has `from <= to` (V24).
    case info(tracks: [TrackID]?, range: Range<Frames>?)
    case create(sampleRate: Int)
}

/// The JSON Schema of one property, with JSON values only.
typealias Schema = [String: any Sendable]

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
    /// A finite number of dB (V9: `Gain(dB:)`).
    static let gain = Kind(schema: ["type": "number"], expected: "a finite number of dB") { value in
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        return Gain(dB: number.doubleValue)
    }
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
private func exactInteger(_ value: Any) -> Int? {
    guard let number = value as? NSNumber, !isBoolean(number), NSNumber(value: number.int64Value) == number,
        (-(1 << 53)...(1 << 53)).contains(number.int64Value)
    else { return nil }
    return Int(number.int64Value)
}

/// The parts of a parameter that `tools/list` and the unknown-argument check need. It erases
/// `Param<Value>`, so one tool lists parameters of different value types.
protocol ParamInfo: Sendable {
    var key: String { get }
    var schema: Schema { get }
    var isRequired: Bool { get }
}

/// One tool argument: its schema and its typed read. An optional parameter has `Value == T?`, so
/// the read of an absent argument gives nil. A defaulted parameter gives the CLI default.
struct Param<Value: Sendable>: ParamInfo {
    let key: String
    let schema: Schema
    let isRequired: Bool
    /// nil in: the argument is absent.
    let read: @Sendable (Any?) throws(ToolError) -> Value

    static func required(_ key: String, _ doc: String, _ kind: Kind<Value>) -> Param {
        Param(key: key, schema: kind.schema.merging(["description": doc]) { $1 }, isRequired: true) {
            value throws(ToolError) in
            guard let value else { throw ToolError("The argument \"\(key)\" is missing.") }
            return try parse(value, key, kind)
        }
    }

    static func optional<T>(_ key: String, _ doc: String, _ kind: Kind<T>) -> Param where Value == T? {
        Param(key: key, schema: kind.schema.merging(["description": doc]) { $1 }, isRequired: false) {
            value throws(ToolError) in
            guard let value else { return nil }
            return try parse(value, key, kind)
        }
    }

    /// `json` is the CLI default as a JSON value. The schema shows it, and an absent argument
    /// reads it.
    static func defaulted(_ key: String, _ doc: String, _ kind: Kind<Value>, _ json: any Sendable) -> Param {
        Param(key: key, schema: kind.schema.merging(["description": doc, "default": json]) { $1 }, isRequired: false) {
            value throws(ToolError) in try parse(value ?? json, key, kind)
        }
    }
}

private func parse<T>(_ value: Any, _ key: String, _ kind: Kind<T>) throws(ToolError) -> T {
    guard let parsed = kind.parse(value) else { throw ToolError("The argument \"\(key)\" must be \(kind.expected).") }
    return parsed
}

/// The arguments of one call. A JSON null counts as absent.
struct Arguments {
    /// The package path as the agent gave it, for the error texts (the CLI uses the typed path).
    let path: String
    var package: URL { URL(filePath: path) }
    private let values: [String: Any]
    private let keys: Set<String>

    /// Refuses an unknown argument, and a `package` that is not a string or is empty.
    init(_ json: [String: Any], params: [any ParamInfo]) throws(ToolError) {
        let keys = Set(params.map(\.key))
        let values = json.filter { !($0.value is NSNull) }
        (self.keys, self.values) = (keys, values)
        if let unknown = values.keys.sorted().first(where: { $0 != "package" && !keys.contains($0) }) {
            throw ToolError("There is no argument \"\(unknown)\".")
        }
        guard let path = values["package"] else { throw ToolError("The argument \"package\" is missing.") }
        guard let path = path as? String, !path.isEmpty else {
            throw ToolError("The argument \"package\" must be the path of a session package.")
        }
        self.path = path
    }

    subscript<Value>(_ param: Param<Value>) -> Value {
        get throws(ToolError) {
            guard keys.contains(param.key) else {
                throw ToolError("The tool reads \"\(param.key)\" but does not list it. This is a bug.")
            }
            return try param.read(values[param.key])
        }
    }
}

/// One MCP tool: the name, the description, the parameters after `package`, and the work of a call.
struct Tool: Sendable {
    let name: String
    let description: String
    let params: [any ParamInfo]
    let make: @Sendable (Arguments) throws(ToolError) -> ToolWork

    /// An edit tool (`saves`) says in its description that a call has no undo.
    init(
        _ name: String, _ description: String, _ params: [any ParamInfo], saves: Bool = true,
        make: @escaping @Sendable (Arguments) throws(ToolError) -> ToolWork
    ) {
        self.name = name
        self.description = saves ? description + " No undo: each call saves the package." : description
        self.params = params
        self.make = make
    }

    var inputSchema: [String: Any] {
        var properties: [String: Any] = [
            "package": [
                "type": "string", "description": "The path of the session package, for example Show.dirigible.",
            ]
        ]
        for param in params { properties[param.key] = param.schema }
        return [
            "type": "object", "properties": properties, "additionalProperties": false,
            "required": ["package"] + params.filter(\.isRequired).map(\.key),
        ]
    }
}
