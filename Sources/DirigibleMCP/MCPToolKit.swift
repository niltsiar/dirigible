import DirigibleCore
import Foundation

/// The text of an MCP tool error result (`isError: true`).
package struct ToolError: Error, Sendable {
    package let message: String
    package init(_ message: String) { self.message = message }
}

/// The edit of one MCP tool call. It gives the new IDs, in the order that the command prints them.
/// `editPackageCore` runs it under the package lock.
typealias ToolEdit = @Sendable (inout Session) throws(SessionError) -> [String]

/// What a tool call does after its arguments are checked.
enum ToolWork: Sendable {
    /// A package edit under the lock. A `ripple` edit also refuses a split take.
    case edit(ripple: Bool, ToolEdit)
    /// `session_info`: no lock, as `dirigible info`. `range` has `from <= to` (V24).
    case info(tracks: [TrackID]?, range: Range<Frames>?, compact: Bool)
    case create(sampleRate: Int)
    /// A paste from another package (decision 0042): files copy or convert under the lock.
    case paste(PasteWork)
    /// `backup_list`: no lock, as `session_info` (decision 0043).
    case backups
    /// `backup_revert`: an edit under the lock that reads the backup.
    case revert(Backup)
    /// `episode_set`: an edit under the lock that can copy an image into the package.
    case episode(EpisodeWork)
    /// `marker_set`: an edit under the lock that can copy an image into the package.
    case marker(MarkerWork)
    /// `episode_get`: no lock, as `session_info`.
    case episodeInfo
    /// `transcript_words`: no lock, as `dirigible transcript words` (decision 0055).
    case words(TranscriptQuery)
    /// `file_prune`: the scan, and with `dryRun` false the moves to the Trash, under the lock.
    case prune(dryRun: Bool)
    /// `record`: only the app records, after the consent of the user (decision 0048).
    case record(RecordRequest)
    /// `loudness`: no lock, as `dirigible loudness`; an empty list is every clip (decision 0049).
    case loudness(clips: [String])
    /// `export` and `render`: no lock, as `dirigible export` and `dirigible render`.
    case export(ExportWork)
    /// `level`: an edit under the lock, as `dirigible level`.
    case level(LevelWork)
    /// `import`: a conversion and an edit under the lock, as `dirigible import`.
    case importFile(ImportWork)
    /// `chapters_export`: no lock, as `dirigible chapters export`.
    case chapters(ChaptersWork)

    /// Long audio work: in the app it runs in `liveJob`, with progress and cancel (decision 0049).
    var isLong: Bool {
        switch self {
        case .loudness, .export, .level, .importFile, .chapters: true
        case .edit, .info, .create, .paste, .backups, .revert, .episode, .marker, .episodeInfo, .prune, .record, .words:
            false
        }
    }
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
    /// A number of dB in `Gain.range` (V9: `Gain(dB:)`).
    static let gain = Kind(
        schema: ["type": "number", "minimum": Gain.range.lowerBound, "maximum": Gain.range.upperBound],
        expected: "a number of dB \(Gain.rangeText)"
    ) { value in
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
        try Self.refuseUnknown(values, keys: keys.union(["package"]))
        guard let path = values["package"] else { throw ToolError("The argument \"package\" is missing.") }
        guard let path = path as? String, !path.isEmpty else {
            throw ToolError("The argument \"package\" must be the path of a session package.")
        }
        // A relative or ~ path resolves against the working folder of the server, which can
        // differ from the folder of the agent, so an edit could change another package.
        guard path.hasPrefix("/") else { throw ToolError("The argument \"package\" must be an absolute path.") }
        self.path = path
    }

    /// Refuses an argument that is not in `keys`. A JSON null counts as absent.
    static func refuseUnknown(_ json: [String: Any], keys: Set<String>) throws(ToolError) {
        let given = json.filter { !($0.value is NSNull) }.keys
        if let unknown = given.sorted().first(where: { !keys.contains($0) }) {
            throw ToolError("There is no argument \"\(unknown)\".")
        }
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

/// One MCP tool: the name, the description, and its body of one of two kinds.
struct Tool: Sendable {
    enum Body: Sendable {
        /// A tool on a package: the parameters after `package`, and the work of a call.
        case package(params: [any ParamInfo], make: @Sendable (Arguments) throws(ToolError) -> ToolWork)
        /// A tool that reads this Mac, not a package. It takes no argument, and the server gives
        /// its text before the bridge, so the call never goes to the app.
        case local(@Sendable () -> String)
    }

    /// The MCP annotations of a tool (decision 0050). A client treats them as untrusted hints.
    enum Hints: Sendable {
        case none
        /// The tool reads and changes nothing.
        case readOnly
        /// The tool records audio: it changes the package, and it records the world.
        case records

        var annotations: [String: Bool]? {
            switch self {
            case .none: nil
            case .readOnly: ["readOnlyHint": true]
            case .records: ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": true]
            }
        }
    }

    let name: String
    let description: String
    let body: Body
    private(set) var hints = Hints.none

    /// This tool with `hints`.
    func hinted(_ hints: Hints) -> Tool {
        var tool = self
        tool.hints = hints
        return tool
    }

    /// The entry of the tool in `tools/list`.
    var listing: [String: Any] {
        var entry: [String: Any] = ["name": name, "description": description, "inputSchema": inputSchema]
        if let annotations = hints.annotations { entry["annotations"] = annotations }
        return entry
    }

    /// The parameters after `package`. A local tool has none.
    var params: [any ParamInfo] {
        guard case .package(let params, _) = body else { return [] }
        return params
    }

    /// The end of the description of each edit tool (decision 0046).
    static let undoNote =
        " When Dirigible lets agents edit open sessions, a call on a package that is open in the app runs there as "
        + "one undo step. On a closed package, the call saves the package and has no undo."

    /// An edit tool (`saves`) says in its description how the call can be undone.
    init(
        _ name: String, _ description: String, _ params: [any ParamInfo], saves: Bool = true,
        make: @escaping @Sendable (Arguments) throws(ToolError) -> ToolWork
    ) {
        self.name = name
        self.description = saves ? description + Self.undoNote : description
        self.body = .package(params: params, make: make)
    }

    /// A local tool that gives `text`.
    init(_ name: String, _ description: String, text: @escaping @Sendable () -> String) {
        (self.name, self.description, self.body) = (name, description, .local(text))
    }

    var inputSchema: [String: Any] {
        guard case .package(let params, _) = body else {
            return ["type": "object", "properties": [String: Any](), "additionalProperties": false]
        }
        var properties: [String: Any] = [
            "package": [
                "type": "string",
                "description":
                    "The absolute path of the session package, for example /Users/me/Podcasts/Show.dirigible.",
            ]
        ]
        for param in params { properties[param.key] = param.schema }
        return [
            "type": "object", "properties": properties, "additionalProperties": false,
            "required": ["package"] + params.filter(\.isRequired).map(\.key),
        ]
    }
}
