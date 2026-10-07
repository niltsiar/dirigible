import DirigibleCore
import Foundation
import Testing

/// C8: each bad argument gives a tool error that names it, and the server answers the `ping` after
/// it, so no input stops the server.
extension MCPToolTests {
    /// A valid value for each property type of `tools/list`.
    private func sample(_ schema: [String: Any]) -> Any {
        if let words = schema["enum"] as? [String] { return words[0] }
        switch schema["type"] as? String {
        case "integer": return 1
        case "number": return 0
        case "boolean": return false
        case "array": return (schema["items"] as? [String: Any])?["type"] as? String == "integer" ? [1] : ["a"]
        default: return "a"
        }
    }

    @Test func badArgumentsAreToolErrors() async throws {
        let listed = try await mcp([modernRequest(1, "tools/list")])
        let tools = result(answer(listed, id: 1))["tools"] as? [[String: Any]] ?? []
        // (tool, arguments, a text that the error must have)
        var cases: [(String, [String: Any], String)] = []
        for tool in tools {
            let name = tool["name"] as? String ?? ""
            let schema = tool["inputSchema"] as? [String: Any] ?? [:]
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            let required = (schema["required"] as? [String] ?? []).filter { $0 != "package" }
            var valid: [String: Any] = ["package": package.path]
            for key in required { valid[key] = sample(properties[key] ?? [:]) }
            for key in required {
                cases.append((name, valid.filter { $0.key != key }, "\"\(key)\" is missing"))
                cases.append((name, valid.merging([key: NSNull()]) { $1 }, "\"\(key)\" is missing"))
            }
            for (key, property) in properties where property["type"] as? String == "integer" {
                for bad: Any in [true, 1.5, "1", 9_007_199_254_740_993, Int64.min] {
                    cases.append((name, valid.merging([key: bad]) { $1 }, "\"\(key)\" must be an integer"))
                }
            }
            cases.append((name, valid.merging(["colour": "red"]) { $1 }, "no argument \"colour\""))
        }
        let pkg = package.path
        cases += [
            ("session_info", ["package": pkg, "from": 96_000, "to": 48_000], "from must not be more than to."),
            ("session_info", ["package": pkg, "from": 96_000], "Give from and to, or neither."),
            ("session_info", ["package": pkg, "tracks": ["a", "zz"]], "no track \"zz\"."),
            ("session_info", ["package": pkg, "tracks": [String]()], "\"tracks\" must be an array of strings"),
            ("track_gain", ["package": pkg, "track": "a", "db": "nan"], "\"db\" must be a finite number of dB."),
            ("track_add", ["package": pkg, "name": "Q", "layout": "quad"], "\"layout\" must be mono or stereo."),
            ("track_add_call", ["package": pkg, "device": "D", "channels": [1, 2]], "Host takes one channel."),
            ("track_add_call", ["package": pkg, "device": "D"], "Give device with channels."),
            ("track_add_call", ["package": pkg, "channels": [1]], "Give device with channels."),
            (
                "track_route", ["package": pkg, "track": "a", "device": "D", "channels": [1, 2, 3]],
                "\"channels\" must be"
            ),
            (
                "track_route", ["package": pkg, "track": "a", "device": "D", "channels": [1], "none": true],
                "Give device with channels, app, or none."
            ),
            ("track_route", ["package": pkg, "track": "a"], "Give device with channels, app, or none."),
            (
                "track_layout", ["package": pkg, "track": "a", "layout": "stereo", "app": "x", "none": true],
                "Give device with channels, app, or none."
            ),
            ("track_mute", ["package": pkg, "tracks": [String]()], "\"tracks\" must be an array of strings"),
            ("track_solo", ["package": pkg, "tracks": ["a"], "off": 1], "\"off\" must be true or false."),
        ]
        let before = try package.xml()
        var lines: [String] = []
        for (index, (name, arguments, _)) in cases.enumerated() {
            lines += [toolCall(index, name, arguments), request(100_000 + index, "ping")]
        }
        let answers = try await mcp(lines)
        for (index, (name, arguments, text)) in cases.enumerated() {
            let refused = toolResult(answer(answers, id: index))
            #expect(refused.isError && refused.text.contains(text), "\(name) \(arguments): \(refused.text)")
            #expect(answers.contains { $0["id"] as? Int == 100_000 + index }, "the ping after \(name) \(arguments)")
        }
        #expect(try package.xml() == before)

        // Pass values of the bounds: 2^40 is an integer, and from equal to to is a range.
        let passed = try await mcp([
            toolCall(1, "session_info", ["package": pkg, "from": 0, "to": 1 << 40]),
            toolCall(2, "session_info", ["package": pkg, "from": 48_000, "to": 48_000]),
        ])
        #expect(!toolResult(answer(passed, id: 1)).isError && !toolResult(answer(passed, id: 2)).isError)
    }
}
