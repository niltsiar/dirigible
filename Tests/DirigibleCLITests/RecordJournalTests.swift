import DirigibleCore
import Foundation
import Testing

/// C46: `dirigible record` writes a `-cli-` journal that ends with `app quit` (decision 0059).
struct RecordJournalTests {
    /// The take does not start: the armed track is not in the session.
    @Test func aFailedRecordEndsItsJournalWithQuit() async throws {
        let package = try TemporaryPackage(Session(sampleRate: 48_000))
        let logs = package.folder.appending(path: "logs")

        let result = try await dirigible(["record", package.path, "--seconds", "1", "--arm", "t9"], logs: logs)

        #expect(result.status == 1)
        #expect(result.stderr.contains("no track \"t9\""), "stderr: \(result.stderr)")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []).filter {
            $0.hasSuffix(".tsv")
        }
        try #require(names.count == 1 && names[0].contains("-cli-"), "files: \(names)")
        let text = String(decoding: try Data(contentsOf: logs.appending(path: names[0])), as: UTF8.self)
        let lines = text.split(separator: "\n")
        #expect(lines.contains { $0.contains("\ttake\tstart-request\t") }, "lines: \(lines)")
        #expect(lines.last?.split(separator: "\t").dropFirst(4).prefix(2) == ["app", "quit"], "lines: \(lines)")
    }
}
