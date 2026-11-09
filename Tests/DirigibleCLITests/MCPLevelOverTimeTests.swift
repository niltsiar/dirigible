import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The `clip_level_over_time` tool of `dirigible mcp` on the files (decisions 0049 and 0064, criterion
/// C15). The packages of `LevelOverTimeCommandTests`; the tool and the command each get their own copy.
struct MCPLevelOverTimeTests {
    /// C15: the tool gives the lines of the command and the same session, also for a clip with no
    /// measurement and for `clear` on a range.
    @Test func toolMatchesCommand() async throws {
        let (cli, tool) = (try LevelOverTimeCommandTests.apart(), try LevelOverTimeCommandTests.apart())

        let run = try await cli.run("clip", "level-over-time", "PKG", "c1", "c2")
        let answers = try await mcp([
            toolCall(1, "clip_level_over_time", ["package": tool.path, "clips": ["c1", "c2"]])
        ])

        try #require(run.status == 0, "\(run)")
        #expect(toolResult(answer(answers, id: 1)) == (String(run.stdout.dropLast()), false), "\(answers)")
        #expect(try cli.holdsTheSameSession(as: tool), "the tool and the command differ")

        let cleared = try await cli.run(
            "clip", "level-over-time", "PKG", "c2", "--clear", "--from", "250000", "--to", "260000")
        let clearedAnswers = try await mcp([
            toolCall(
                1, "clip_level_over_time",
                ["package": tool.path, "clips": ["c2"], "clear": true, "from": 250_000, "to": 260_000])
        ])
        #expect(cleared.stdout == "c2: ride removed\n", "\(cleared)")
        #expect(toolResult(answer(clearedAnswers, id: 1)) == (String(cleared.stdout.dropLast()), false))
        #expect(try cli.holdsTheSameSession(as: tool), "the range remove differs")
    }

    /// C15: a cancel before the read, in the middle of it, and at the last check leaves the same
    /// `session.xml`: the call gets no answer and no ride.
    @Test func cancelWritesNothing() throws {
        func control(stopAt stop: Int, polls: OSAllocatedUnfairLock<Int>) -> CallControl {
            CallControl(
                token: nil, interval: .zero, send: { _ in },
                poll: { _ in
                    polls.withLock {
                        $0 += 1
                        return $0 >= stop
                    }
                }, step: {})
        }
        let work = RideWork(clips: ["c1", "c2"], clear: false, range: nil)
        let counted = OSAllocatedUnfairLock(initialState: 0)
        let all = try LevelOverTimeCommandTests.touching()
        _ = try work.run(all.url, path: all.path, control: control(stopAt: .max, polls: counted))
        let last = counted.withLock { $0 }
        try #require(last > 2, "a ride polled \(last) times")

        for stop in [1, last / 2, last] {
            let package = try LevelOverTimeCommandTests.touching()
            let before = try package.xml()
            let polls = OSAllocatedUnfairLock(initialState: 0)

            let thrown = #expect(throws: ToolError.self) {
                try work.run(package.url, path: package.path, control: control(stopAt: stop, polls: polls))
            }

            #expect(thrown?.message == cancelledMessage, "stop \(stop): \(String(describing: thrown))")
            #expect(polls.withLock { $0 } == stop, "stop \(stop): the cancel came at another poll")
            #expect(try package.xml() == before, "stop \(stop): a cancelled ride changed session.xml")
        }
    }
}
