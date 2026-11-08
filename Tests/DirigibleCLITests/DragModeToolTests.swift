import DirigibleCore
import Foundation
import Testing

/// `clip_move` and `clip_nudge` with `mode`, and `clip_shuffle`, on fixture S of
/// `DragModeCommandLineTests`: each tool gives the `session.xml` and the text of its command
/// (decision 0020, criteria C40, C46). The tests sit in this target because the compare runs the
/// `dirigible` binary.
struct DragModeToolTests {
    private func call(_ tool: String, _ arguments: [String: Any], on package: TemporaryPackage) async throws -> (
        text: String, isError: Bool
    ) {
        let answers = try await mcp([toolCall(1, tool, arguments.merging(["package": package.path]) { $1 })])
        return toolResult(answer(answers, id: 1))
    }

    @Test func theToolsMatchTheCommands() async throws {
        let rows: [(tool: String, arguments: [String: Any], command: [String])] = [
            (
                "clip_move", ["clip": "b", "track": "t1", "start": 144_000, "mode": "no-overlap"],
                ["clip", "move", "PKG", "b", "--track", "t1", "--start", "144000", "--mode", "no-overlap"]
            ),
            (
                "clip_move", ["clip": "b", "track": "t1", "start": 170_000, "mode": "crossfade"],
                ["clip", "move", "PKG", "b", "--track", "t1", "--start", "170000", "--mode", "crossfade"]
            ),
            (
                "clip_nudge", ["clips": ["b"], "by": 48_000, "mode": "no-overlap"],
                ["clip", "nudge", "PKG", "b", "--by", "48000", "--mode", "no-overlap"]
            ),
            (
                "clip_shuffle", ["clip": "b", "track": "t2", "start": 100_000],
                ["clip", "shuffle", "PKG", "b", "--track", "t2", "--start", "100000"]
            ),
        ]
        for row in rows {
            let (tool, cli) = (try DragModeCommandLineTests.package(), try DragModeCommandLineTests.package())
            let before = try tool.xml()
            let reply = try await call(row.tool, row.arguments, on: tool)
            let result = try await cli.run(row.command)
            #expect(reply.text == "OK" && !reply.isError && result.status == 0, "\(row.tool): \(reply) \(result)")
            #expect(try tool.xml() == cli.xml(), "\(row.tool) gives the package of its command")
            #expect(try tool.xml() != before, "\(row.tool) changes the package")
        }
    }

    @Test func aRefusalHasTheTextOfTheCommand() async throws {
        let package = try DragModeCommandLineTests.package()
        let before = try package.xml()
        let reply = try await call(
            "clip_move", ["clip": "b", "track": "t1", "start": 144_001, "mode": "no-overlap"], on: package)
        #expect(reply.isError && reply.text == "clip \"b\" overlaps clip \"c\".", "\(reply)")
        #expect(try package.xml() == before)

        let shuffle = try await call(
            "clip_move", ["clip": "b", "track": "t1", "start": 144_000, "mode": "shuffle"], on: package)
        #expect(shuffle.isError, "shuffle is no mode of a move: \(shuffle)")
        #expect(try package.xml() == before)
    }
}
