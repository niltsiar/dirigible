import DirigibleAudio
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

/// The edit of `transcript_import` with `take`. It gets the take map of its session, so the closed
/// path reads the anchors under the lock and the open window gives its stored map.
typealias TakeImportEdit = @Sendable (inout Session, TakeMap) throws(SessionError) -> [String]

/// What a tool call does after its arguments are checked.
enum ToolWork: Sendable {
    /// A package edit under the lock. A `ripple` edit also refuses a split take.
    case edit(ripple: RippleNeed, ToolEdit)
    /// `transcript_import` with `take`: an edit under the lock that reads the take map (decision 0061).
    case takeImport(take: Int, TakeImportEdit)
    /// `session_info`: no lock, as `dirigible info`. `range` has `from <= to` (V24).
    case info(tracks: [TrackID]?, range: Range<Frames>?, compact: Bool)
    /// `session_create`: an empty session or a copy of a template, with no lock (decision 0079).
    case create(NewSessionSource)
    /// A paste from another package (decision 0042): files copy or convert under the lock.
    case paste(PasteWork)
    /// `backup_list`: no lock, as `session_info` (decision 0043).
    case backups
    /// `bin_list`: no lock, as `dirigible bin list` (F22).
    case bins
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
    /// `transport_play`, `transport_stop`, and `transport_locate`: only the app has a playhead.
    case transport(TransportWork)
    /// `loudness`: no lock, as `dirigible loudness`; an empty list is every clip (decision 0049).
    case loudness(clips: [String])
    /// `export` and `render`: no lock, as `dirigible export` and `dirigible render`.
    case export(ExportWork)
    /// `export_stems`: no lock, as `dirigible export-stems`.
    case stems(StemsWork)
    /// `level`: an edit under the lock, as `dirigible level`.
    case level(LevelWork)
    /// `duck`: a speech read and an edit under the lock, as `dirigible duck`.
    case duck(DuckWork)
    /// `clip_level_over_time`: a measure and an edit under the lock, as
    /// `dirigible clip level-over-time` (decision 0060).
    case ride(RideWork)
    /// `clip_sync`: a read of the clip and the reference and an edit under the lock, as
    /// `dirigible clip sync` (decision 0076).
    case sync(SyncWork)
    /// `track_match_voice` with `reference`: a read of the clips and an edit under the lock, as
    /// `dirigible track match-voice` (decision 0074). The other modes are an `.edit`.
    case matchVoice(MatchWork, MatchWork.Request)
    /// `import`: a conversion and an edit under the lock, as `dirigible import`.
    case importFile(ImportWork)
    /// `import_session`: file copies and an edit under the lock, as `dirigible import-session` (decision 0075).
    case importSession(ImportSessionWork)
    /// `clip_split_stereo`: a pair writer and an edit under the lock, as `dirigible clip split-stereo`.
    case splitStereo(SplitWork)
    /// `clip_denoise` and `clip_repair`: a render and an edit under the lock, as `dirigible clip denoise` and
    /// `dirigible clip repair` (decisions 0054 and 0064).
    case clipRender(ClipRenderWork)
    /// `chapters_export`: no lock, as `dirigible chapters export`.
    case chapters(ChaptersWork)
    /// `transcript_export`: no lock, as `dirigible transcript export` (decision 0061).
    case transcriptExport(TranscriptExportWork)
    /// `take_map`: no lock, as `dirigible take map` (decision 0061).
    case takeMap(TakeMapQuery)
    /// `silences`, `nearest_pause`, and `meter`: no lock, as their commands (decision 0062).
    case read(ReadWork)
    /// `transcribe`: the engine and an edit under the lock, as `dirigible transcribe` (decision 0065).
    case transcribe(TranscribeWork)
    /// `batch`: many steps in one edit, one undo step in the app and one save on the files (decision 0063).
    case batch(BatchWork)

    /// Long audio work: in the app it runs in `liveJob`, with progress and cancel (decision 0049).
    var isLong: Bool {
        switch self {
        case .loudness, .export, .stems, .level, .duck, .ride, .sync, .matchVoice, .importFile, .importSession,
            .splitStereo, .clipRender, .chapters,
            .transcriptExport, .read, .transcribe:
            true
        case .edit, .takeImport, .info, .create, .paste, .backups, .bins, .revert, .episode, .marker, .episodeInfo,
            .prune,
            .record, .transport, .words,
            .takeMap, .batch:
            false
        }
    }
}

/// The JSON Schema of one property, with JSON values only.
typealias Schema = [String: any Sendable]

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

func parse<T>(_ value: Any, _ key: String, _ kind: Kind<T>) throws(ToolError) -> T {
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

    /// Whether a call of the tool can be a step of a batch (decision 0063). Each package tool names
    /// it at its definition, with no default value; a local tool is `.alone`.
    enum BatchRole: Sendable {
        case step
        case alone
    }

    let name: String
    let description: String
    let body: Body
    let batch: BatchRole
    private(set) var hints = Hints.none
    /// What a long tool writes outside the package.
    enum Output: String {
        case file, folder
    }

    /// The output of a long tool that writes outside the package, else nil: a call that the bridge
    /// loses can still write it, so the lost-call and limit texts say to check the output.
    private(set) var output: Output?

    /// This tool with `hints`.
    func hinted(_ hints: Hints) -> Tool {
        var tool = self
        tool.hints = hints
        return tool
    }

    /// This tool with `output`.
    func writing(_ output: Output = .file) -> Tool {
        var tool = self
        tool.output = output
        return tool
    }

    /// The output of the tool of `name` that `writing(_:)` marks, else nil.
    static func output(of name: String) -> Output? { all.first { $0.name == name }?.output }

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
        _ name: String, _ description: String, _ params: [any ParamInfo], saves: Bool = true, batch: BatchRole,
        make: @escaping @Sendable (Arguments) throws(ToolError) -> ToolWork
    ) {
        self.name = name
        self.description = saves ? description + Self.undoNote : description
        self.body = .package(params: params, make: make)
        self.batch = batch
    }

    /// A local tool that gives `text`.
    init(_ name: String, _ description: String, text: @escaping @Sendable () -> String) {
        (self.name, self.description, self.body, self.batch) = (name, description, .local(text), .alone)
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
