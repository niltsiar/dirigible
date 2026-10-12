import Foundation

/// The JSON-RPC 2.0 side of `dirigible mcp` (decision 0041): one request line in, one answer line
/// out. It has no stdio and no ArgumentParser, so the app can import it (decision 0046).
package struct MCPServer {
    /// `initialize` selects the legacy era for the life of the process.
    enum Era { case modern, legacy }
    private(set) var era = Era.modern

    /// The legacy versions, newest first. `initialize` gets the client version when it is here.
    package init() {}

    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    /// One request line to one answer line, or nil for a notification or an empty line. Each line
    /// gets its answer here, so no input stops the server.
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
                    "_meta": ["io.modelcontextprotocol/serverInfo": serverInfo],
                ], cached: true)
        case "ping": return reply(id, [:])
        case "tools/list":
            let list = Tool.all.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema] }
            return reply(id, ["tools": list], cached: true)
        case "tools/call":
            guard let name = params["name"] as? String else {
                return reply(id, error: -32602, "tools/call needs a name.")
            }
            guard let tool = Tool.all.first(where: { $0.name == name }) else {
                return reply(id, error: -32602, "no tool \(name).")
            }
            guard let arguments = params["arguments"].map({ $0 as? [String: Any] }) ?? [:] else {
                return reply(id, error: -32602, "the arguments of tools/call are not an object.")
            }
            let (text, isError) = tool.call(arguments)
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
        return reply(id, ["protocolVersion": version, "capabilities": capabilities, "serverInfo": serverInfo])
    }

    /// A modern request with a `_meta` version that is not 2026-07-28 gets -32022. A request with
    /// no `_meta` version is served (U13).
    private func versionRefusal(_ id: Any, _ params: [String: Any]) -> String? {
        let meta = params["_meta"] as? [String: Any]
        guard let asked = meta?["io.modelcontextprotocol/protocolVersion"] as? String, asked != Self.modernVersion
        else { return nil }
        return reply(
            id, error: -32022, "the protocol version \(asked) is not supported.",
            data: ["supported": [Self.modernVersion] + Self.legacyVersions, "requested": asked])
    }

    private let capabilities = ["tools": [String: Any]()]
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
