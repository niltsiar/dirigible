import DirigibleCore
import Foundation
import Testing

extension MatchVoiceCommandTests {
    /// The track of the reference clip is left out with its own line, and the other track matches.
    /// Named alone, it exits 1 with no target.
    @Test func referenceTrackIsLeftOut() async throws {
        let package = try Self.package()

        let result = try await package.run("track", "match-voice", "PKG", "--reference", "R", "ref", "t1")

        let session = try package.read()
        let text = "ref: left out, the track of the reference\n" + (try Self.line("t1", in: session)) + "\n"
        #expect(result == CLIResult(status: 0, stdout: text, stderr: ""), "\(result)")
        #expect(session.track("ref")?.match == nil)

        let alone = try await package.run("track", "match-voice", "PKG", "--reference", "R", "ref")
        #expect(alone.status == 1 && alone.stderr.contains("the track of the reference clip"), "\(alone)")
    }
}
