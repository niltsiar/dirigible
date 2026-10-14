import Foundation

/// The JSON-RPC 2.0 side of `dirigible mcp` (decision 0041): one request line in, one answer line
/// out. It has no stdio and no ArgumentParser, so the app can import it (decision 0046).
package struct MCPServer {
    /// `initialize` selects the legacy era for the life of the process.
    enum Era { case modern, legacy }
    private(set) var era = Era.modern
    /// The `clientInfo` of `initialize`, for the agent name of a legacy call (decision 0046).
    private var initializeClient = ClientInfo()

    /// Gives the result of a `tools/call` from the app, or nil to run the call on the files.
    package typealias Route = (_ tool: String, _ arguments: [String: Any], _ client: ClientInfo, _ control: CallControl)
        -> (text: String, isError: Bool)?
    private let route: Route?
    /// Writes one notification line to stdout (decision 0049).
    private let send: (String) -> Void
    /// Reads stdin when the flag is true, and gives true when a buffered line cancels the request
    /// with this ID (decision 0049).
    private let pollCancel: (NSObject, Bool) -> Bool
    private let pollInterval: Duration
    private let step: () -> Void

    /// With `route`, `dirigible mcp` is the bridge to the app (decision 0046). A call reads stdin
    /// for its cancel at most once in `pollInterval`. `step` runs after each progress report of a
    /// call; tests hold the job with it.
    package init(
        route: Route? = nil, send: @escaping (String) -> Void = { _ in },
        pollCancel: @escaping (NSObject, Bool) -> Bool = { _, _ in false }, pollInterval: Duration = .milliseconds(100),
        step: @escaping () -> Void = {}
    ) {
        (self.route, self.send, self.pollCancel, self.pollInterval, self.step) = (
            route, send, pollCancel, pollInterval, step
        )
    }

    /// The legacy versions, newest first. `initialize` gets the client version when it is here.
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    /// One request line to one answer line, or nil for a notification, an empty line, or a
    /// cancelled call. Each other line gets its answer here, so no input stops the server.
    package mutating func answer(_ line: String) -> String? {
        guard !line.allSatisfy(\.isWhitespace) else { return nil }
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: .fragmentsAllowed) else {
            return reply(NSNull(), error: -32700, "the line is not JSON.")
        }
        let request = message as? [String: Any]
        let id = request?["id"]
        // A message with no id, or a null id, is a notification: it gets no answer.
        if let request, request["method"] is String, id == nil || id is NSNull { return nil }
        guard let request, let id, request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String
        else { return reply(id ?? NSNull(), error: -32600, "the line is not a JSON-RPC 2.0 request.") }
        let params = request["params"] as? [String: Any] ?? [:]
        if method == "initialize" { return initialize(id, params) }
        if era == .modern, let refusal = versionRefusal(id, params) { return refusal }
        switch method {
        case "server/discover" where era == .modern:
            return reply(
                id,
                [
                    "supportedVersions": [Self.modernVersion], "capabilities": capabilities,
                    "instructions": AgentManual.instructions,
                    "_meta": ["io.modelcontextprotocol/serverInfo": serverInfo],
                ], cached: true)
        case "ping": return reply(id, [:])
        case "prompts/list": return reply(id, ["prompts": AgentManual.promptList], cached: true)
        case "prompts/get":
            guard let name = params["name"] as? String else {
                return reply(id, error: -32602, "prompts/get needs a name.")
            }
            guard let recipe = AgentManual.recipes.first(where: { $0.name == name }) else {
                return reply(id, error: -32602, "no prompt \(name).")
            }
            guard let package = (params["arguments"] as? [String: Any])?["package"] as? String else {
                return reply(id, error: -32602, "the prompt \(name) needs the argument package, a string.")
            }
            return reply(id, recipe.prompt(package: package))
        case "tools/list":
            let list = Tool.all.map(\.listing)
            return reply(id, ["tools": list], cached: true)
        case "tools/call":
            // A call that the client cancelled while it waited does not run (decision 0049).
            let requestID = id as? NSObject
            if let requestID, pollCancel(requestID, true) { return nil }
            guard let name = params["name"] as? String else {
                return reply(id, error: -32602, "tools/call needs a name.")
            }
            guard let tool = Tool.all.first(where: { $0.name == name }) else {
                return reply(id, error: -32602, "no tool \(name).")
            }
            guard let arguments = params["arguments"].map({ $0 as? [String: Any] }) ?? [:] else {
                return reply(id, error: -32602, "the arguments of tools/call are not an object.")
            }
            let client = ClientInfo(meta(params)?["io.modelcontextprotocol/clientInfo"]) ?? initializeClient
            let pollCancel = pollCancel
            let control = CallControl(
                token: meta(params)?["progressToken"], interval: pollInterval, send: send,
                poll: { read in requestID.map { pollCancel($0, read) } ?? false }, step: step)
            // A local tool reads this Mac, so its call never goes to the app.
            var routed: (text: String, isError: Bool)?
            if case .package = tool.body { routed = route?(name, arguments, client, control) }
            let (text, isError) = routed ?? tool.call(arguments, control: control)
            // MCP 2026-07-28: no response for a cancelled request.
            if control.cancelSeen { return nil }
            return reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
        default: return reply(id, error: -32601, "no method \(method).")
        }
    }

    /// The modern protocol version (2026-07-28).
    static let modernVersion = "2026-07-28"

    /// Selects the legacy era with the client version when it is supported, else the newest one.
    /// A second `initialize` is refused.
    private mutating func initialize(_ id: Any, _ params: [String: Any]) -> String {
        guard era == .modern else { return reply(id, error: -32600, "the server is already initialized.") }
        let asked = params["protocolVersion"] as? String ?? ""
        let version = Self.legacyVersions.contains(asked) ? asked : Self.legacyVersions[0]
        era = .legacy
        initializeClient = ClientInfo(params["clientInfo"]) ?? ClientInfo()
        return reply(
            id,
            [
                "protocolVersion": version, "capabilities": capabilities, "serverInfo": serverInfo,
                "instructions": AgentManual.instructions,
            ])
    }

    /// A modern request with a `_meta` version that is not 2026-07-28 gets -32022. A request with
    /// no `_meta` version is served (U13).
    private func versionRefusal(_ id: Any, _ params: [String: Any]) -> String? {
        guard let asked = meta(params)?["io.modelcontextprotocol/protocolVersion"] as? String,
            asked != Self.modernVersion
        else { return nil }
        return reply(
            id, error: -32022, "the protocol version \(asked) is not supported.",
            data: ["supported": [Self.modernVersion] + Self.legacyVersions, "requested": asked])
    }

    private func meta(_ params: [String: Any]) -> [String: Any]? { params["_meta"] as? [String: Any] }

    private let capabilities = ["tools": [String: Any](), "prompts": [:]]
    private let serverInfo = ["name": "dirigible", "version": "1"]

    /// A modern result has `resultType`, and a `cached` one (`server/discover`, `tools/list`) has
    /// the cache hints too (U2 probe: Claude Code refuses a result with no hints). A legacy result
    /// keeps the 2025-11-25 shape.
    private func reply(_ id: Any, _ result: [String: Any], cached: Bool = false) -> String {
        var result = result
        if era == .modern {
            result["resultType"] = "complete"
            // The tool set does not change while the process runs (default, decisions.tsv).
            if cached { (result["ttlMs"], result["cacheScope"]) = (3_600_000, "public") }
        }
        return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func reply(_ id: Any, error code: Int, _ message: String, data: [String: Any]? = nil) -> String {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        return Self.encode(["jsonrpc": "2.0", "id": id, "error": error])
    }
}

extension MCPServer {
    /// Compact JSON on one line: no pretty print, so a newline in a text stays `\n` (C15).
    static func encode(_ object: [String: Any]) -> String {
        // Each object holds only JSON types, so the encode cannot fail.
        let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data ?? Data(), as: UTF8.self)
    }
}
