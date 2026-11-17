import Foundation

/// The end of one `dirigible mcp` child: the parsed answer lines, the lines that break the frame
/// rule of `mcpLines`, the exit status or the signal number, and whether the limit stopped it.
struct MCPOutcome {
    var answers: [Answer] = []
    var frameProblems: [String] = []
    var status: Int32 = -1
    var signaled = false
    var timedOut = false

    /// True when the child ended by a signal that the limit did not send, or by an exit that is not 0.
    var endedBadly: Bool { !timedOut && (signaled || status != 0) }
    var end: String { signaled ? "by signal \(status)" : "with exit \(status)" }

    func answer(id: Int) -> Answer? { answers.first { ($0["id"] as? Int) == id } }
}

/// Runs `dirigible mcp` with `lines` on stdin from a file and gives its end as a value. It takes a
/// slot of `Slots.shared`, stops the child at `limit`, and records no issue, so a caller can send
/// the calls with no answer again, alone. It checks the frame rule of `mcpLines` on each line
/// itself: a JSON object with `jsonrpc` 2.0 and an `id`, a null `id` only on a -32700 or -32600
/// error, and a last line that ends with a line feed. `mcp(_:)` and `mcpLines` assert exit 0 and
/// the helper of `CLI.swift` records an issue at its limit, so neither fits.
func mcpChild(_ lines: [String], limit: Duration) async throws -> MCPOutcome {
    let folder = FileManager.default.temporaryDirectory.appending(path: "dirigible-mcp-fuzz-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = folder.appending(path: "stdin")
    let output = folder.appending(path: "stdout")
    try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: input)
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let process = childProcess(dirigibleBinary, ["mcp"], in: folder)
    let end = try await launch(process, input: input, output: output, errors: nil, limit: limit)
    var outcome = MCPOutcome(status: end.status, signaled: end.signaled, timedOut: end.timedOut)
    let text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
    if !text.isEmpty, !text.hasSuffix("\n") { outcome.frameProblems.append("the last stdout line has no line feed") }
    for line in text.split(separator: "\n") {
        guard let answer = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? Answer,
            answer["jsonrpc"] as? String == "2.0", let id = answer["id"]
        else {
            outcome.frameProblems.append("a stdout line is not a JSON-RPC answer: \(line.prefix(200))")
            continue
        }
        if id is NSNull, ![-32700, -32600].contains(errorCode(answer)) {
            outcome.frameProblems.append(
                "a null id on an answer that is no -32700 or -32600 error: \(line.prefix(200))")
        }
        outcome.answers.append(answer)
    }
    return outcome
}
