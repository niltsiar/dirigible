import Foundation
import Testing

/// The JSON-RPC line protocol of `dirigible mcp` in both eras (decision 0041).
struct MCPProtocolTests {
    @Test func initializeNegotiatesTheVersion() async throws {
        for (asked, given) in [
            ("2025-11-25", "2025-11-25"), ("2025-06-18", "2025-06-18"), ("2025-03-26", "2025-03-26"),
            ("1999-01-01", "2025-11-25"),
        ] {
            let answers = try await mcp([
                request(1, "initialize", ["protocolVersion": asked, "capabilities": [:], "clientInfo": ["name": "t"]])
            ])
            let initialized = result(answer(answers, id: 1))
            #expect(initialized["protocolVersion"] as? String == given, "asked \(asked)")
            #expect(initialized["capabilities"].flatMap { $0 as? [String: Any] }?["tools"] is [String: Any])
            #expect((initialized["serverInfo"] as? [String: Any])?["name"] as? String == "dirigible")
            #expect(initialized["resultType"] == nil, "a legacy result keeps the 2025-11-25 shape")
        }
    }
}

extension MCPProtocolTests {
    /// The first line of Claude Code 2.1.292, as the U2 probe recorded it, with its string `id`.
    static let discoverLine =
        #"{"jsonrpc":"2.0","id":"server-discover-probe-1","method":"server/discover","params":{"_meta":{"#
        + #""io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"#
        + #""name":"claude-code","title":"Claude Code","version":"2.1.292"},"#
        + #""io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"#
        + #""url":{}}}}}}"#
    /// The second line of the probe: `tools/list` with an integer `id`.
    static let toolsListLine =
        #"{"method":"tools/list","jsonrpc":"2.0","id":0,"params":{"_meta":{"#
        + #""io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#

    @Test func discoverListsTheModernVersion() async throws {
        let answers = try await mcp([Self.discoverLine, Self.toolsListLine])
        let discovered = result(answer(answers, id: "server-discover-probe-1"))
        #expect(discovered["resultType"] as? String == "complete")
        #expect(discovered["supportedVersions"] as? [String] == [modernVersion])
        #expect((discovered["capabilities"] as? [String: Any])?["tools"] is [String: Any])
        #expect((discovered["ttlMs"] as? Int).map { $0 >= 0 } == true)
        #expect(discovered["cacheScope"] as? String == "public")
        let meta = discovered["_meta"] as? [String: Any]
        #expect((meta?["io.modelcontextprotocol/serverInfo"] as? [String: Any])?["name"] as? String == "dirigible")
        // Claude Code refused a tools/list result with no resultType, ttlMs, or cacheScope (U2 probe).
        let listed = result(answer(answers, id: 0))
        #expect(listed["resultType"] as? String == "complete")
        #expect(listed["tools"] is [Any])
        #expect((listed["ttlMs"] as? Int).map { $0 >= 0 } == true)
        #expect(listed["cacheScope"] as? String == "public")
    }

    @Test func aModernRequestNeedsASupportedVersion() async throws {
        let modern = try await mcp([
            modernRequest(1, "tools/list"), request(2, "tools/list"),
            modernRequest(3, "tools/list", version: "1900-01-01"),
        ])
        #expect(result(answer(modern, id: 1))["tools"] is [Any])
        #expect(result(answer(modern, id: 2))["tools"] is [Any], "a request with no _meta version is served (U13)")
        let refused = answer(modern, id: 3)
        #expect(errorCode(refused) == -32022)
        let data = (refused["error"] as? [String: Any])?["data"] as? [String: Any]
        #expect(data?["supported"] as? [String] == [modernVersion, "2025-11-25", "2025-06-18", "2025-03-26"])
        #expect(data?["requested"] as? String == "1900-01-01")

        let legacy = try await mcp([
            request(1, "initialize", ["protocolVersion": "2025-11-25", "capabilities": [:]]),
            modernRequest(2, "tools/list", version: "1900-01-01"),
            request(3, "initialize", ["protocolVersion": "2025-11-25", "capabilities": [:]]),
        ])
        #expect(result(answer(legacy, id: 2))["tools"] is [Any], "the legacy era ignores _meta")
        #expect(errorCode(answer(legacy, id: 3)) == -32600, "a second initialize is refused")
    }

    @Test func pingAnswersEmpty() async throws {
        let modern = try await mcp([modernRequest(1, "ping")])
        #expect(result(answer(modern, id: 1)) as? [String: String] == ["resultType": "complete"])
        let legacy = try await mcp([
            request(1, "initialize", ["protocolVersion": "2025-11-25", "capabilities": [:]]), request(2, "ping"),
        ])
        let ping = answer(legacy, id: 2)
        #expect(ping["result"] is [String: Any] && result(ping).isEmpty)
    }

    @Test func malformedLinesGetErrors() async throws {
        let bad: [(String, Int, Int?)] = [
            ("not JSON", -32700, nil), ("[1,2]", -32600, nil), (#"{"jsonrpc":"2.0","id":2}"#, -32600, 2),
            (#"{"jsonrpc":"1.0","id":3,"method":"ping"}"#, -32600, 3), (request(4, "no/method"), -32601, 4),
            (modernRequest(5, "tools/call", ["name": "no_tool", "arguments": [String: Any]()]), -32602, 5),
            (modernRequest(6, "tools/call"), -32602, 6),
        ]
        var lines: [String] = []
        for (index, (text, _, _)) in bad.enumerated() { lines += [text, request(100 + index, "ping")] }
        let answers = try await mcp(lines + ["", request(200, "ping")])
        #expect(answers.count == bad.count * 2 + 1, "the empty line gets no answer: \(answers)")
        for (index, (text, code, id)) in bad.enumerated() where answers.count > index * 2 + 1 {
            let error = answers[index * 2]
            #expect(errorCode(error) == code, "\(text)")
            #expect(error["id"] as? Int == id && (id != nil || error["id"] is NSNull), "\(text)")
            #expect(answers[index * 2 + 1]["id"] as? Int == 100 + index, "the ping after \(text) is answered")
        }
    }

    @Test func notificationsGetNoAnswer() async throws {
        let answers = try await mcp([
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/no-such-thing"}"#,
            request(1, "ping"),
            #"{"jsonrpc":"2.0","method":"ping","id":null}"#,
            request(2, "ping"),
        ])
        #expect(answers.compactMap { $0["id"] as? Int } == [1, 2], "\(answers)")
    }

    @Test func answersBeforeStdinClosesAndExitsAtEOF() async throws {
        let (first, status) = try await mcpOverPipe(
            request(1, "initialize", ["protocolVersion": "2025-11-25", "capabilities": [:]]))
        let answer = first.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? Answer }
        #expect(answer?["id"] as? Int == 1, "no answer arrived while stdin was open: \(String(describing: first))")
        #expect(status == 0, "the server did not exit 0 after stdin closed")
    }
}
