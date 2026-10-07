import Foundation
import Testing

/// One answer line of `dirigible mcp`, parsed.
typealias Answer = [String: Any]

/// The protocol version of Claude Code 2.1.292 (the U2 probe of run 2026-10-07-mcp-cli).
let modernVersion = "2026-07-28"

/// Runs `dirigible mcp` with `lines` on stdin, from a file, and gives the answer lines, parsed.
/// It checks the frame rule (C15) on each line: a JSON object with `jsonrpc` 2.0 and an `id`,
/// with a null `id` only on a -32700 or -32600 error. It also checks that the server exits 0 at
/// the end of stdin (C16).
func mcp(_ lines: [String]) async throws -> [Answer] {
    let folder = FileManager.default.temporaryDirectory.appending(path: "dirigible-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = folder.appending(path: "stdin")
    try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: input)
    let result = try await dirigible(["mcp"], input: input)
    #expect(result.status == 0, "dirigible mcp exited \(result.status): \(result.stderr)")
    #expect(result.stdout.isEmpty || result.stdout.hasSuffix("\n"), "the last stdout line has no newline")
    return result.stdout.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { line in
        let answer = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? Answer
        guard let answer, answer["jsonrpc"] as? String == "2.0", let id = answer["id"] else {
            Issue.record("stdout has a line that is not a JSON-RPC answer: \(line)")
            return [:]
        }
        if id is NSNull, ![-32700, -32600].contains(errorCode(answer)) {
            Issue.record("an answer has a null id but is not a -32700 or -32600 error: \(line)")
        }
        return answer
    }
}

/// One request line with compact JSON.
func request(_ id: Any, _ method: String, _ params: [String: Any]? = nil) -> String {
    var object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
    if let params { object["params"] = params }
    return line(object)
}

/// A request with the modern `_meta` protocol version, as Claude Code sends it.
func modernRequest(_ id: Any, _ method: String, _ params: [String: Any] = [:], version: String = modernVersion)
    -> String
{
    var params = params
    params["_meta"] = ["io.modelcontextprotocol/protocolVersion": version]
    return request(id, method, params)
}

/// Compact JSON. An object that is not JSON gives an empty line, which the server ignores.
func line(_ object: Any) -> String {
    let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data ?? Data(), as: UTF8.self)
}

/// The answer with `id`, or an empty answer and an issue.
func answer(_ answers: [Answer], id: Int) -> Answer { answer(answers, id: id as AnyHashable) }
func answer(_ answers: [Answer], id: String) -> Answer { answer(answers, id: id as AnyHashable) }

private func answer(_ answers: [Answer], id: AnyHashable) -> Answer {
    guard let found = answers.first(where: { ($0["id"] as? AnyHashable) == id }) else {
        Issue.record("no answer with id \(id) in \(answers)")
        return [:]
    }
    return found
}

/// The `error.code` of an answer, or nil for a result.
func errorCode(_ answer: Answer) -> Int? { (answer["error"] as? [String: Any])?["code"] as? Int }

func result(_ answer: Answer) -> [String: Any] { answer["result"] as? [String: Any] ?? [:] }

/// Starts `dirigible mcp` with a pipe on stdin, writes `line`, and waits for the first stdout
/// line while stdin stays open. Then it closes stdin and waits for the exit. Each wait has its own
/// limit, so a server that holds its answer until EOF fails the test and does not hang it (C16).
/// The limit is the 30 s of each CLI child: under the load of the suite, a child can start many
/// seconds late.
func mcpOverPipe(_ line: String, limit: Duration = .seconds(30)) async throws -> (first: String?, status: Int32?) {
    let folder = FileManager.default.temporaryDirectory.appending(path: "dirigible-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = folder.appending(path: "stdout")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let stdin = Pipe()
    let process = Process()
    process.executableURL = Bundle(for: TemporaryPackage.self).bundleURL.deletingLastPathComponent()
        .appending(path: "dirigible")
    process.arguments = ["mcp"]
    process.standardInput = stdin
    process.standardOutput = try FileHandle(forWritingTo: output)
    await Slots.shared.started()
    defer { Slots.shared.ended() }
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    stdin.fileHandleForWriting.write(Data((line + "\n").utf8))

    var first: String?
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while first == nil, clock.now < deadline {
        let text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        if let end = text.firstIndex(of: "\n") {
            first = String(text[..<end])
        } else {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    try stdin.fileHandleForWriting.close()
    let exitDeadline = clock.now + limit
    while process.isRunning, clock.now < exitDeadline { try await Task.sleep(for: .milliseconds(20)) }
    return (first, process.isRunning ? nil : process.terminationStatus)
}

/// A modern `tools/call` request line.
func toolCall(_ id: Int, _ name: String, _ arguments: [String: Any]) -> String {
    modernRequest(id, "tools/call", ["name": name, "arguments": arguments])
}

/// The one text item of a tool result and its `isError`. It records an issue when the result has
/// another shape (C9: one text item, no `structuredContent`).
func toolResult(_ answer: Answer) -> (text: String, isError: Bool) {
    let result = result(answer)
    let content = result["content"] as? [[String: Any]] ?? []
    if content.count != 1 || content.first?["type"] as? String != "text" || result["structuredContent"] != nil {
        Issue.record("the tool result is not one text item: \(answer)")
    }
    return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? true)
}

/// The text of a CLI error line, without "Error: " and the newline.
func errorText(_ result: CLIResult) -> String {
    String(result.stderr.dropFirst("Error: ".count).dropLast())
}

/// Starts `dirigible mcp` with the read end of its stdout closed (and of its stderr, with
/// `closesStderr`), sends one `ping`, and waits for the exit with a limit. Gives whether a signal
/// ended it, the exit status, and the stderr text.
func mcpWithClosedOutput(closesStderr: Bool, limit: Duration = .seconds(30)) async throws -> (
    signaled: Bool, status: Int32?, stderr: String
) {
    let folder = FileManager.default.temporaryDirectory.appending(path: "dirigible-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let errors = folder.appending(path: "stderr")
    FileManager.default.createFile(atPath: errors.path, contents: nil)
    let (stdin, stdout, stderr) = (Pipe(), Pipe(), Pipe())
    let process = Process()
    process.executableURL = Bundle(for: TemporaryPackage.self).bundleURL.deletingLastPathComponent()
        .appending(path: "dirigible")
    process.arguments = ["mcp"]
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = closesStderr ? stderr : try FileHandle(forWritingTo: errors)
    await Slots.shared.started()
    defer { Slots.shared.ended() }
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    try stdout.fileHandleForReading.close()
    if closesStderr { try stderr.fileHandleForReading.close() }
    stdin.fileHandleForWriting.write(Data((request(1, "ping") + "\n").utf8))
    try stdin.fileHandleForWriting.close()
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while process.isRunning, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    guard !process.isRunning else { return (false, nil, "no exit in \(limit)") }
    let text = String(decoding: try Data(contentsOf: errors), as: UTF8.self)
    return (process.terminationReason == .uncaughtSignal, process.terminationStatus, text)
}
