import DirigibleCore
import Foundation
import Testing

/// The tool `take_map` on a closed package, and the sync key of `session_info` (decision 0061,
/// C6). The open-window cases are in `LiveTakeMapTests`.
struct MCPTakeMapToolTests {
    @Test func takeMapGivesTheTextOfTheCommand() async throws {
        let package = try TakeMapCommandTests.twoTakes()
        let path = package.path

        let answers = try await mcp([
            toolCall(1, "take_map", ["package": path, "frames": [100, 48_000], "take": 2]),
            toolCall(2, "take_map", ["package": path, "frames": [480_100], "take": 2, "timeline": true]),
            toolCall(3, "take_map", ["package": path, "frames": [100]]),
            toolCall(4, "take_map", ["package": path, "frames": [-1], "take": 1, "timeline": true]),
            toolCall(6, "take_map", ["package": path, "frames": [-1], "take": 1]),
            toolCall(5, "session_info", ["package": path, "compact": true]),
        ])

        #expect(toolResult(answer(answers, id: 1)) == ("100 t1:480100\n48000 cut\n", false))
        #expect(toolResult(answer(answers, id: 2)) == ("480100 t1:100\n", false))
        #expect(toolResult(answer(answers, id: 3)) == ("Give --take: the session has takes 1, 2.", true))
        #expect(toolResult(answer(answers, id: 4)) == ("Each frame must be 0 to 1099511627776.", true))
        #expect(toolResult(answer(answers, id: 6)) == ("-1 cut\n", false))
        let info = toolResult(answer(answers, id: 5)).text
        #expect(
            info.contains(
                #""takeSync":[{"offset":0,"state":"inSync","take":1},{"offset":480000,"state":"inSync","take":2}]"#),
            "\(info)")
    }

    @Test func anAnchorFaultIsAToolErrorAndAnInfoKey() async throws {
        let package = try TakeMapCommandTests.twoTakes()
        let anchor = package.url.appending(path: "Capture/take2.anchor")
        chmod(anchor.path, 0o000)
        defer { chmod(anchor.path, 0o644) }

        let answers = try await mcp([
            toolCall(1, "take_map", ["package": package.path, "frames": [100], "take": 2]),
            toolCall(2, "session_info", ["package": package.path]),
            toolCall(3, "take_map", ["package": package.path, "frames": [100], "take": 1]),
        ])

        #expect(
            toolResult(answer(answers, id: 1))
                == (
                    "Cannot read the take anchor file Capture/take2.anchor (errno 13), so the take time is not known.",
                    true
                )
        )
        let info = toolResult(answer(answers, id: 2))
        #expect(!info.isError && info.text.contains(#""takeSyncFault":{"errno":13,"file":"Capture/take2.anchor"}"#))
        #expect(info.text.contains(#""takeSync":[{"offset":0,"state":"inSync","take":1}]"#), "\(info.text)")
        #expect(toolResult(answer(answers, id: 3)) == ("100 t1:100\n", false))
    }

    @Test func noTakeAudioIsAToolError() async throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        let package = try TemporaryPackage(session)

        let answers = try await mcp([toolCall(1, "take_map", ["package": package.path, "frames": [0]])])

        #expect(toolResult(answer(answers, id: 1)) == ("The session has no take audio with a take time.", true))
    }
}
