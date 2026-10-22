import Foundation
import Testing

/// The CLI edit path does no take sync work: `editPackageCore` reads no anchor (decision 0061, C7).
struct PackageEditTakeSyncTests {
    /// The anchor is a FIFO, whose open blocks with no writer, so a CLI insert that read it would
    /// hang. Then the anchor has mode 000: the MCP insert, which reads it, gives no note line.
    @Test func aCLIEditReadsNoAnchor() async throws {
        let package = try MCPTakeSyncNoteTests.oneTake()
        let anchor = package.url.appending(path: "Capture/take1.anchor")
        let bytes = try Data(contentsOf: anchor)
        try FileManager.default.removeItem(at: anchor)
        #expect(mkfifo(anchor.path, 0o644) == 0)

        let cli = try await package.run("clip", "ripple-insert", "PKG", "--at", "0", "--length", "24000")

        #expect(cli.status == 0, "\(cli)")
        try FileManager.default.removeItem(at: anchor)
        try bytes.write(to: anchor)
        chmod(anchor.path, 0o000)
        defer { chmod(anchor.path, 0o644) }
        let answers = try await mcp([MCPTakeSyncNoteTests.insert(1, package.path, at: 0, track: [])])
        #expect(toolResult(answer(answers, id: 1)) == ("OK", false))
    }
}
