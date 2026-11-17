import DirigibleCore
import Foundation
import Testing

/// C11, C12, C14, C16: the tool arguments of `dirigible mcp`, read from `tools/list`. The calls of
/// one tool go to one `dirigible mcp` child with a `ping` after each call, so a crash or a hang
/// names its call. A wrong JSON type is a tool error that names its key (family S); a stress value
/// of the right type does not stop the server (family V); an error keeps each byte of the package.
/// A call with no answer is sent again, alone, to a new child, and only a call with no answer there
/// too is an issue (a hang or a crash). Each issue names the seed, the case, the family, and the
/// tool.
struct MCPFuzzTests {
    static let seeds: [UInt64] = [20_261_117]
    static let aloneLimit: Duration = .seconds(30)

    /// The limit of the child of `tool`: the budget of the test (C16).
    static func childLimit(_ tool: String) -> Duration { .seconds(20) }

    /// The JSON type of a property of a tool, from its `inputSchema`.
    enum Shape {
        case string
        case boolean
        case integer(minimum: Int?, maximum: Int?, words: [Int]?)
        case number(low: Double, high: Double, level: Bool, isGain: Bool)
        case strings(minItems: Int)
        case integers(minItems: Int, maxItems: Int?)
        case choice([String])

        init?(_ schema: [String: Any]) {
            if let words = schema["enum"] as? [String] {
                self = .choice(words)
                return
            }
            switch schema["type"] as? String {
            case "string": self = .string
            case "boolean": self = .boolean
            case "integer":
                self = .integer(
                    minimum: schema["minimum"] as? Int, maximum: schema["maximum"] as? Int,
                    words: schema["enum"] as? [Int])
            case "number":
                self = .number(
                    low: schema["minimum"] as? Double ?? -96, high: schema["maximum"] as? Double ?? 96,
                    level: schema["exclusiveMaximum"] != nil, isGain: schema["minimum"] != nil)
            case "array":
                let items = (schema["items"] as? [String: Any])?["type"] as? String
                let minItems = schema["minItems"] as? Int ?? 0
                if items == "string" {
                    self = .strings(minItems: minItems)
                } else if items == "integer" {
                    self = .integers(minItems: minItems, maxItems: schema["maxItems"] as? Int)
                } else {
                    return nil
                }
            default: return nil
            }
        }
    }

    /// One `tools/call` line and what the test expects of its answer.
    struct Call: Sendable {
        var id: Int
        var family: String
        var text: String
        var line: String
        var package: URL?
        /// The text that an error must hold (family S); nil for family V.
        var expected: String?
        /// The line is not JSON (the value `1e309`), so the server answers -32700 with a null `id`.
        var isUnparseable: Bool { line.contains("1e309") }
    }

    static let raw = "@@1e309@@"

    /// `line` of a tool call, with the raw text of a number that JSON cannot hold.
    static func toolLine(_ id: Int, _ tool: String, _ arguments: [String: Any]) -> String {
        toolCall(id, tool, arguments).replacing("\"\(raw)\"", with: "1e309")
    }

    static func isPath(_ key: String) -> Bool { key == "out" || key == "file" || key.hasSuffix("_file") }

    /// A valid value for `shape`.
    static func sample(_ shape: Shape, key: String, folder: URL) -> Any {
        switch shape {
        case .string: isPath(key) ? folder.appending(path: "out.wav").path : "a"
        case .boolean: false
        case .integer(let minimum, let maximum, let words):
            // The end of a range is above its start, so a pair rule never comes before the bad key.
            words?.first ?? min(max(["to", "until"].contains(key) ? 2_000 : 1_000, minimum ?? 1), maximum ?? Int.max)
        case .number(_, _, let level, _): level ? -6 : 1
        case .strings: ["a"]
        case .integers: [["to", "until"].contains(key) ? 2_000 : 1_000]
        case .choice(let words): words[0]
        }
    }

    /// The values of the family V table for `shape`.
    static func stress(_ shape: Shape, key: String, folder: URL) -> [Any] {
        let big = 1 << 53
        switch shape {
        case .string:
            var values: [Any] = [
                "", " ", "zz-none", String(repeating: "x", count: 100_000), "a\tb\nc\u{FFFE}\u{1F399}",
            ]
            if isPath(key) {
                values += ["out.wav", "out.srt", "out.vtt", "out.zz"].map { folder.appending(path: $0).path }
                values.append(folder.appending(path: "Show.dirigible/inside.wav").path)
            } else {
                values.append("../x")
            }
            return values
        case .boolean: return [true, false]
        case .integer(let minimum, let maximum, let words):
            if let words { return words }
            var values = [-1, 0, 1, 1 << 40, (1 << 40) + 1, big, -big]
            if let minimum { values += [minimum - 1, minimum] }
            if let maximum { values += [maximum, maximum + 1] }
            return values
        case .number(let low, let high, _, _):
            return [low, low - 0.001, low + 0.001, high, high - 0.001, high + 0.001, 0.0, -0.0, Double("1e-320")!]
        case .strings: return [["a"], ["a", "a"], [String](repeating: "a", count: 10_000)]
        case .integers: return [[1], [1, 1], [Int](repeating: 1, count: 10_000)]
        case .choice(let words): return words
        }
    }

    /// The calls of one tool: one case for each row of family S that has a key of its type, and 3 cases of family V.
    static func calls(
        tool: [String: Any], others: [String], run: FuzzRun, random: inout SplitMix, index: inout Int
    ) throws -> [Call] {
        let name = tool["name"] as? String ?? ""
        let schema = tool["inputSchema"] as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        let required = (schema["required"] as? [String] ?? []).filter { $0 != "package" }
        let shapes = properties.compactMapValues { Shape($0) }
        var calls: [Call] = []

        func make(
            _ family: String, _ text: String, _ expected: String?,
            _ change: (inout [String: Any], URL) -> Void
        ) throws {
            let folder = try run.caseFolder(index)
            let package = folder.appending(path: "Show.dirigible")
            var arguments: [String: Any] = [:]
            if properties["package"] != nil { arguments["package"] = package.path }
            for key in required {
                guard let shape = shapes[key] else { continue }
                arguments[key] = sample(shape, key: key, folder: folder)
            }
            change(&arguments, folder)
            let id = 2 * calls.count + 1
            calls.append(
                Call(
                    id: id, family: family, text: "case \(index) family \(family) \(text)",
                    line: toolLine(id, name, arguments), package: package, expected: expected))
            index += 1
        }
        func pick(_ match: (Shape) -> Bool) -> String? {
            shapes.filter { $0.key != "package" && match($0.value) }.keys.sorted().randomElement(using: &random)
        }
        func row(
            _ family: String, key: String?, values: [Any], expected: (Any) -> String?
        ) throws {
            guard let key, let value = values.randomElement(using: &random) else { return }
            let text = expected(value).map { "\"\(key)\" must be " + $0 } ?? ""
            try make(family, "key \(key) value \(value)", text) { arguments, _ in arguments[key] = value }
        }

        try row(
            "S1", key: pick { if case .string = $0 { true } else { false } },
            values: [1, true, [Any](), [String: Any](), ["a"]]
        ) { _ in "" }
        try row(
            "S2", key: pick { if case .boolean = $0 { true } else { false } }, values: [1, 0, "true"]
        ) { _ in "true or false" }
        if let key = pick({ if case .integer = $0 { true } else { false } }),
            let value = [
                1e300, -0.5, 9_007_199_254_740_994, [String: Any](), [1],
            ].randomElement(using: &random) as Any?
        {
            var expected = "an integer"
            if case .integer(let minimum, let maximum, let words)? = shapes[key],
                minimum != nil || maximum != nil || words != nil
            {
                expected = ""
            }
            try make("S3", "key \(key) value \(value)", "\"\(key)\" must be \(expected)") { arguments, _ in
                arguments[key] = value
            }
        }
        try row(
            "S4", key: pick { if case .number(_, _, _, true) = $0 { true } else { false } },
            values: ["0", true, raw, -1e300]
        ) { _ in "a number of dB" }
        try row(
            "S5", key: pick { if case .strings = $0 { true } else if case .integers = $0 { true } else { false } },
            values: ["a", [String: Any](), [1, "a"], [NSNull()]]
        ) { _ in "an array" }
        try row(
            "S6", key: pick { if case .integers(_, let maxItems) = $0 { maxItems == 2 } else { false } },
            values: [[Int](), [1, 2, 3], [0], [1.5]]
        ) { "\($0)" == "[0]" ? nil : "" }
        if let key = pick({ if case .choice = $0 { true } else { false } }), case .choice(let words)? = shapes[key] {
            let first = words[0]
            let value = [first.prefix(1).uppercased() + first.dropFirst(), first + " ", ""].randomElement(
                using: &random)!
            try make("S7", "key \(key) value \(value)", "\"\(key)\" must be \(words.joined(separator: " or "))") {
                arguments, _ in arguments[key] = value
            }
        }
        if properties["package"] != nil {
            let value =
                ["", "Show.dirigible", "~/Show.dirigible", 1, [Any]()].randomElement(using: &random) as Any? ?? ""
            try make("S8", "package \(value)", "\"package\" must be") { arguments, _ in arguments["package"] = value }
        }
        let letters = (0..<Int.random(in: 1...12, using: &random)).map { _ in
            Character(UnicodeScalar(UInt8.random(in: 97...122, using: &random)))
        }
        let unknown = String(letters)
        try make("S9", "unknown key \(unknown)", "There is no argument \"\(unknown)\".") { arguments, _ in
            arguments[unknown] = 1
        }
        let own = Set(properties.keys)
        let foreign = others.filter { !own.contains($0) }.randomElement(using: &random)
        for key in [String(repeating: "k", count: 200)] + (foreign.map { [$0] } ?? []) {
            try make("S10", "key \(key.prefix(20))", "There is no argument") { arguments, _ in arguments[key] = 1 }
        }

        let candidates = shapes.keys.filter { $0 != "package" }.sorted()
        for _ in 0..<(candidates.isEmpty ? 0 : 3) {
            let chosen = candidates.shuffled(using: &random).prefix(
                Int.random(in: 1...min(3, candidates.count), using: &random))
            try make("V", "keys \(chosen.joined(separator: ","))", nil) { arguments, folder in
                for key in chosen {
                    // The path values name the case folder, so no write leaves it.
                    if let shape = shapes[key],
                        let value = stress(shape, key: key, folder: folder).randomElement(using: &random)
                    {
                        arguments[key] = value
                    }
                }
            }
        }
        return calls
    }

    // MARK: Checks

    /// The problems of one call, from the outcome of the child that answered it.
    static func verify(_ call: Call, _ outcome: MCPOutcome, run: FuzzRun) -> [String] {
        if call.isUnparseable {
            let refused = outcome.answers.contains { $0["id"] is NSNull && errorCode($0) == -32700 }
            return refused ? [] : ["no -32700 answer for a line that is not JSON"]
        }
        guard let answer = outcome.answer(id: call.id) else { return [] }
        var problems: [String] = []
        let result = result(answer)
        let content = result["content"] as? [[String: Any]] ?? []
        if content.count != 1 || content.first?["type"] as? String != "text" || result["structuredContent"] != nil {
            problems.append("the result is not one text item: \(answer)")
        }
        let text = content.first?["text"] as? String ?? ""
        let isError = result["isError"] as? Bool ?? true
        if let expected = call.expected, !(isError && (expected.isEmpty || text.contains(expected))) {
            problems.append("isError \(isError), the text lacks \"\(expected)\": \(text.prefix(300))")
        }
        guard let package = call.package else { return problems }
        if isError {
            if let now = try? PackageSnapshot(of: package), now != run.baseline {
                problems.append("an error changed the package: \(now.difference(from: run.baseline))")
            }
        } else if (try? Session(contentsOf: package)) == nil {
            problems.append("a call that gave no error left a package that does not read")
        }
        return problems
    }

    /// Sends the calls of one tool to one child, checks each answer, and sends each call with no
    /// answer again, alone. It gives the problems and prints one line when the child ends badly.
    static func check(tool: String, _ calls: [Call], run: FuzzRun) async -> [String] {
        func label(_ call: Call) -> String { "seed \(run.seed) \(call.text) tool \(tool): \(call.line.prefix(160))" }
        var problems: [String] = []
        do {
            let lines = calls.flatMap { [$0.line, request($0.id + 1, "ping")] }
            let outcome = try await mcpChild(lines, limit: childLimit(tool))
            problems += outcome.frameProblems.map { "seed \(run.seed) tool \(tool): \($0)" }
            func answered(_ call: Call, _ outcome: MCPOutcome) -> Bool {
                (call.isUnparseable || outcome.answer(id: call.id) != nil) && outcome.answer(id: call.id + 1) != nil
            }
            let unanswered = calls.filter { !answered($0, outcome) }
            if outcome.timedOut || outcome.status != 0 || !unanswered.isEmpty {
                print(
                    "tool \(tool): child ended \(outcome.end) timed out \(outcome.timedOut), \(unanswered.count) ids with no answer"
                )
            }
            for call in calls where answered(call, outcome) {
                problems += verify(call, outcome, run: run).map { "\(label(call)): \($0)" }
            }
            for call in unanswered {
                let alone = try await mcpChild([call.line, request(call.id + 1, "ping")], limit: aloneLimit)
                guard answered(call, alone), !alone.timedOut, !alone.endedBadly else {
                    problems.append(
                        "\(label(call)): alone, the child ended \(alone.end), timed out \(alone.timedOut), "
                            + "answered \(answered(call, alone))")
                    continue
                }
                problems += verify(call, alone, run: run).map { "\(label(call)): \($0)" }
            }
            if outcome.endedBadly && unanswered.isEmpty {
                problems.append("seed \(run.seed) tool \(tool): the child ended \(outcome.end)")
            }
        } catch {
            problems.append("seed \(run.seed) tool \(tool): the test failed to run the child: \(error)")
        }
        return problems
    }

    /// C11 and C12 share the walk: the families S and V of each tool of `tools/list`.
    static func fuzz(test: String, seed: UInt64, families: Set<String>) async throws {
        let listed = try await mcp([modernRequest(1, "tools/list")])
        let tools = result(answer(listed, id: 1))["tools"] as? [[String: Any]] ?? []
        let names = tools.compactMap { $0["name"] as? String }
        #expect(names.contains("track_rename"), "tools/list holds track_rename: \(names)")
        let keys = tools.flatMap {
            Array(((($0["inputSchema"] as? [String: Any])?["properties"]) as? [String: Any] ?? [:]).keys)
        }
        let run = try FuzzRun(test: test, seed: seed)
        defer { run.remove() }
        var random = SplitMix(seed: seed)
        var index = 0
        var perTool: [(String, [Call])] = []
        for tool in tools {
            let all = try calls(tool: tool, others: Array(Set(keys)).sorted(), run: run, random: &random, index: &index)
            perTool.append(
                (tool["name"] as? String ?? "", all.filter { families.contains(String($0.family.prefix(1))) }))
        }
        let all = perTool.flatMap(\.1)
        for (family, count) in Dictionary(grouping: all, by: \.family).mapValues(\.count).sorted(by: { $0.key < $1.key }
        ) {
            print("\(test) seed \(seed) family \(family): \(count) cases in \(perTool.count) tools")
        }
        var problems: [String] = []
        await withTaskGroup(of: [String].self) { group in
            for (tool, calls) in perTool where !calls.isEmpty {
                group.addTask { await check(tool: tool, calls, run: run) }
            }
            for await found in group { problems += found }
        }
        for problem in problems { Issue.record(Comment(rawValue: problem)) }
    }

    @Test(arguments: seeds)
    func badArgumentTypesAreToolErrors(seed: UInt64) async throws {
        try await Self.fuzz(test: "badArgumentTypesAreToolErrors", seed: seed, families: ["S"])
    }

    @Test(arguments: seeds)
    func stressValuesKeepThePackageOnError(seed: UInt64) async throws {
        try await Self.fuzz(test: "stressValuesKeepThePackageOnError", seed: seed, families: ["V"])
    }
}
