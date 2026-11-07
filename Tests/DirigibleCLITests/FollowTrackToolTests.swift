import DirigibleCore
import Foundation
import Testing

/// `track_follow` and the ripple tools on fixture F of `FollowTrackCommandLineTests`: each tool
/// gives the `session.xml` and the text of its command (decision 0073, criteria C36, C37, C51, C55).
/// The tests sit in this target because the compare runs the `dirigible` binary.
struct FollowTrackToolTests {
    private func call(_ tool: String, _ arguments: [String: Any], on package: TemporaryPackage) async throws -> (
        text: String, isError: Bool
    ) {
        let answers = try await mcp([toolCall(1, tool, arguments.merging(["package": package.path]) { $1 })])
        return toolResult(answer(answers, id: 1))
    }

    @Test func theToolMatchesTheCommand() async throws {
        let (tool, cli) = (
            try FollowTrackCommandLineTests.package(follow: []), try FollowTrackCommandLineTests.package(follow: [])
        )
        let reply = try await call("track_follow", ["tracks": ["bed", "sfx"]], on: tool)
        let result = try await cli.run("track", "follow", "PKG", "bed", "sfx")
        #expect(reply.text == "OK" && !reply.isError && result == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try tool.read().tracks.filter(\.isFollowTrack).map(\.id.rawValue) == ["bed", "sfx"])
        #expect(try tool.xml() == cli.xml())

        let off = try await call("track_follow", ["tracks": ["bed"], "off": true], on: tool)
        _ = try await cli.run("track", "follow", "PKG", "bed", "--off")
        #expect(off.text == "OK" && !off.isError)
        #expect(try tool.read().tracks.filter(\.isFollowTrack).map(\.id.rawValue) == ["sfx"])
        #expect(try tool.xml() == cli.xml())

        let unknown = try await call("track_follow", ["tracks": ["zz"]], on: tool)
        #expect(unknown.isError && unknown.text == "no track \"zz\".")
    }

    /// C36: the tool returns the text of the command.
    @Test func aRippleToolOverlapHasTheSameText() async throws {
        let package = try FollowTrackCommandLineTests.package(w: 48_001)
        let before = try package.xml()
        let reply = try await call(
            "clip_ripple_delete", ["from": [240_000], "to": [336_000]], on: package)
        #expect(reply.isError && reply.text == "clip \"x\" follows ripples and would cover clip \"w\".")
        #expect(try package.xml() == before)
    }

    /// C51: `track` `["bed"]` cuts the bed, and the package equals the one that the command cuts.
    @Test func aRippleToolWithTrackCutsTheFollowTrack() async throws {
        let (tool, cli) = (try FollowTrackCommandLineTests.package(), try FollowTrackCommandLineTests.package())
        let reply = try await call(
            "clip_ripple_delete", ["from": [240_000], "to": [336_000], "track": ["bed"]], on: tool)
        let result = try await cli.run(FollowTrackCommandLineTests.cut + ["--track", "bed"])
        #expect(!reply.isError && result.status == 0, "\(reply) \(result)")
        #expect(try tool.read().track("bed")?.clips.map(\.range) == [0..<240_000, 240_000..<864_000])
        #expect(try tool.xml() == cli.xml())
    }

    /// C55: each track follows and the call names none.
    @Test func aRippleToolOfOnlyFollowTracksHasTheText() async throws {
        let package = try FollowTrackCommandLineTests.package(follow: ["host", "bed", "sfx"])
        let before = try package.xml()
        let reply = try await call("clip_ripple_delete", ["from": [240_000], "to": [336_000]], on: package)
        #expect(
            reply.isError
                && reply.text == "no track to edit: each track of the ripple follows ripples, and the edit names none.")
        #expect(try package.xml() == before)
    }
}
