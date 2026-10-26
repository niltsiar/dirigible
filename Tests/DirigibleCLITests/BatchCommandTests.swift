import DirigibleCore
import Foundation
import Testing

@testable import DirigibleMCP

/// `dirigible batch <package> <file|->` (decision 0063): the calls of the tool `batch` as one
/// read-edit-save. Exit 0, 1, 2, 3, and 64 (decision 0011).
struct BatchCommandTests {
    let package: TemporaryPackage

    init() throws { package = try MCPBatchToolTests.fixture() }

    /// Writes `text` next to the package and returns its path.
    func file(_ text: String, in package: TemporaryPackage) throws -> String {
        let url = package.folder.appending(path: "calls.json")
        try Data(text.utf8).write(to: url)
        return url.path
    }

    func json(_ calls: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: calls), as: UTF8.self)
    }

    func run(_ calls: [[String: Any]], on package: TemporaryPackage? = nil) async throws -> CLIResult {
        let package = package ?? self.package
        return try await package.run("batch", "PKG", try file(try json(calls), in: package))
    }

    static let refusedText = "Error: calls[1] track_rename failed, so the batch changed nothing: no track \"X\".\n"

    @Test func exit0AppliesTheCalls() async throws {
        let result = try await run([MCPBatchToolTests.addT2, MCPBatchToolTests.fade])

        #expect(result == CLIResult(status: 0, stdout: "calls[0] track_add: T2\ncalls[1] clip_fade: OK\n", stderr: ""))
        let session = try package.read()
        #expect(session.track("T2") != nil && session.clip("a")?.clip.fades.fadeIn == Frames(480))
    }

    @Test func exit1RefusesAFailedCallAndChangesNothing() async throws {
        let before = try package.xml()

        let result = try await run([MCPBatchToolTests.addT2, MCPBatchToolTests.badRename])

        #expect(result == CLIResult(status: 1, stdout: "", stderr: Self.refusedText), "BATCH-S2-7 \(result)")
        #expect(try package.xml() == before, "BATCH-S2-8 the refused batch saved")
    }

    @Test func exit2RefusesAPendingTake() async throws {
        try package.edit {
            try $0.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["V"]))
        }
        let before = try package.xml()

        let result = try await run([MCPBatchToolTests.addT2])

        #expect(result.status == 2 && result.stdout.isEmpty, "\(result)")
        #expect(result.stderr == "Error: \(pendingTakeMessage(package.path))\n", "\(result.stderr)")
        #expect(try package.xml() == before)
    }

    @Test func exit3RefusesARippleOnASplitTake() async throws {
        let take = try await MCPBatchToolTests.takePackage()
        let before = try take.xml()

        let result = try await run(MCPBatchToolTests.splitThenRipple, on: take)

        let text = "calls[1] clip_ripple_delete failed, so the batch changed nothing: "
        #expect(result.status == 3 && result.stdout.isEmpty, "\(result)")
        #expect(result.stderr == "Error: \(text)\(splitTakeMessage(take.path))\n", "\(result.stderr)")
        #expect(try take.xml() == before)
    }

    /// Exit 64: the file is not valid, the count is out of the limit, or a call is not a step. The
    /// count text is the text of the tool.
    @Test(arguments: [
        ("not json", "Error: calls.json is not JSON.\n"),
        ("{}", "Error: The argument \"calls\" must be an array of 1 to 100 calls.\n"),
        ("[]", "Error: The argument \"calls\" must be an array of 1 to 100 calls.\n"),
        ("[1]", "Error: The argument \"calls\" must be an array of 1 to 100 calls.\n"),
        (
            #"[{"tool":"track_add","arguments":{"name":"A","layout":"mono"}},{"tool":"export","arguments":{}}]"#,
            "Error: calls[1] export failed, so the batch changed nothing: export cannot run in a batch: a step is an "
                + "edit of session.xml only.\n"
        ),
    ]) func exit64RefusesAFileThatIsNotACallList(text: String, stderr: String) async throws {
        let before = try package.xml()

        let result = try await package.run("batch", "PKG", try file(text, in: package))

        #expect(result.status == 64 && result.stdout.isEmpty, "\(result)")
        #expect(
            result.stderr == stderr.replacing("calls.json", with: package.folder.appending(path: "calls.json").path))
        #expect(try package.xml() == before)
    }

    @Test func stdinGivesTheSameLines() async throws {
        let other = try MCPBatchToolTests.fixture()
        let calls = [MCPBatchToolTests.addT2, MCPBatchToolTests.fade]
        let fromFile = try await run(calls)

        let input = other.folder.appending(path: "stdin.json")
        try Data(try json(calls).utf8).write(to: input)
        let fromStdin = try await dirigible(["batch", other.path, "-"], input: input)

        #expect(fromFile.status == 0 && fromStdin == fromFile, "\(fromFile) \(fromStdin)")
        #expect(try package.read() == other.read())
    }
}
