import Foundation
import Testing

/// The tools `devices` and `apps` (run 2026-10-13-agent-workflows, W2, W4): they read this
/// Mac, not a package, so they take no argument.
struct MCPSourceToolTests {
    /// W2, a live smoke check: each tool gives the lines of its command. The lists of this Mac can
    /// change between two reads, so the check holds the invariants of `DeviceCommandTests` only.
    @Test func theToolsGiveTheOwnerLines() async throws {
        let answers = try await mcp([toolCall(1, "devices", [:]), toolCall(2, "apps", [:])])
        for (id, fields, empty) in [(1, 4, "No input devices."), (2, 3, "No apps.")] {
            let (text, isError) = toolResult(answer(answers, id: id))
            #expect(!isError, "\(text)")
            guard text != empty else { continue }
            #expect(text.hasSuffix("\n"), "\(text)")
            var keys: Set<Substring> = []
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                #expect(parts.count == fields && !parts[0].isEmpty, "line \(line)")
                #expect(keys.insert(parts[0]).inserted, "\(parts[0]) repeats")
            }
        }
    }

    /// W4: an argument, also `package`, is refused with the text of an unknown argument.
    @Test func anArgumentIsRefused() async throws {
        let answers = try await mcp([
            toolCall(1, "devices", ["package": "/tmp/Show.dirigible"]), toolCall(2, "apps", ["all": true]),
        ])
        #expect(toolResult(answer(answers, id: 1)) == ("There is no argument \"package\".", true))
        #expect(toolResult(answer(answers, id: 2)) == ("There is no argument \"all\".", true))
    }
}
