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
            (
                "track_rename", ["package": "Show.dirigible", "track": "a", "name": "X"],
                "\"package\" must be an absolute path."
            ),
            (
                "track_rename", ["package": "~/Show.dirigible", "track": "a", "name": "X"],
                "\"package\" must be an absolute path."
            ),
            (
                "session_create", ["package": "New.dirigible", "sample_rate": 48_000],
                "\"package\" must be an absolute path."
            ),
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
            (
                "marker_set", ["package": pkg, "name": "M", "at": 0, "kind": "note"],
                "\"kind\" must be marker or chapter."
            ),
            ("clip_gain", ["package": pkg, "clips": ["A1", "A1"], "db": 0], "Clip \"A1\" is given twice."),
            ("clip_fade", ["package": pkg, "clip": "A1"], "Give in, out, or both."),
            ("clip_crossfade", ["package": pkg, "clip": "A1", "length": 3], "A crossfade length is an even number"),
            (
                "clip_crossfade", ["package": pkg, "clip": "A1", "length": -2],
                "\"length\" must be an integer, 0 or more."
            ),
            (
                "clip_clear", ["package": pkg, "track": ["a"], "from": 96_000, "to": 48_000],
                "from must not be more than to."
            ),
            ("clip_clear", ["package": pkg, "track": [String](), "from": 0, "to": 1], "\"track\" must be an array"),
            (
                "clip_trim", ["package": pkg, "clip": "A1", "from": 96_000, "to": 48_000],
                "from must not be more than to."
            ),
            (
                "clip_paste", ["package": pkg, "track": ["a"], "from": 96_000, "to": 48_000, "at": 0],
                "from must not be more than to."
            ),
            (
                "clip_paste", ["package": pkg, "track": ["a"], "from": 0, "to": 1, "at": 0, "onto": ["a", "b"]],
                "Give one onto for each track, or none."
            ),
            ("clip_split_at", ["package": pkg, "track": ["a"], "at": [Int]()], "\"at\" must be an array of integers"),
            ("clip_paste_clips", ["package": pkg, "clips": [String](), "at": 0], "\"clips\" must be an array"),
            ("clip_ripple_delete", ["package": pkg, "from": 48_000, "to": 48_000], "from must be less than to."),
            (
                "clip_ripple_insert", ["package": pkg, "at": 0, "length": -1],
                "\"length\" must be an integer, 0 or more."
            ),
            (
                "clip_ripple_trim", ["package": pkg, "clip": "A1", "edge": "middle", "by": 1],
                "\"edge\" must be start or end."
            ),
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
            toolCall(3, "clip_crossfade", ["package": pkg, "clip": "A1", "length": 4]),
        ])
        #expect(!toolResult(answer(passed, id: 1)).isError && !toolResult(answer(passed, id: 2)).isError)
        // The even rule passes 4; the session then refuses the crossfade, because no clip touches A1.
        #expect(toolResult(answer(passed, id: 3)) == ("no clip touches the crossfade edge of clip \"A1\".", true))
    }
}
