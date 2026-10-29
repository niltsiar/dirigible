import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The `clip_repair` tool of `dirigible mcp` on the files (decision 0064, criteria C12 and C19).
/// The packages of `DenoiseCommandTests`; the tool and the command each get their own copy.
struct MCPRepairTests {
    /// C12: the tool gives the lines and the session of `clip repair`. A corner over the limit of the
    /// session rate gives the text of the command and writes nothing.
    @Test func toolMatchesCommand() async throws {
        let (cli, tool) = (try DenoiseCommandTests.package(), try DenoiseCommandTests.package())

        let run = try await cli.run(
            "clip", "repair", "PKG", "c1", "c2", "--rumble", "120", "--clipping", "95", "--sibilance", "8",
            "--sibilance-hz", "5000")
        let arguments: [String: Any] = [
            "package": tool.path, "clips": ["c1", "c2"], "rumble": 120, "clipping": 95, "sibilance": 8,
            "sibilance_hz": 5_000,
        ]
        let answers = try await mcp([toolCall(1, "clip_repair", arguments)])

        try #require(run.status == 0, "\(run)")
        #expect(toolResult(answer(answers, id: 1)) == (String(run.stdout.dropLast()), false), "\(answers)")
        #expect(try cli.holdsTheSameSession(as: tool), "the tool and the command differ")
        #expect(DenoiseCommandTests.clips(tool) == DenoiseCommandTests.clips(cli))
        let effects = try RepairCommandTests.effects(of: tool)
        #expect(
            effects == [
                .declip(Declip(percent: 95)!), .rumble(Rumble(hertz: 120)!), .deess(DeEss(hertz: 5_000, decibels: 8)!),
            ], "\(effects)")

        let (slow, slowTool) = (
            try await RepairCommandTests.package(rate: 22_050), try await RepairCommandTests.package(rate: 22_050)
        )
        let before = (try slowTool.xml(), DenoiseCommandTests.clips(slowTool))
        let refused = try await slow.run("clip", "repair", "PKG", "c1", "--sibilance", "--sibilance-hz", "9923")
        let call = toolCall(
            1, "clip_repair", ["package": slowTool.path, "clips": ["c1"], "sibilance": 10, "sibilance_hz": 9_923])
        let toolRefused = try await mcp([call])
        #expect(refused.status == 1 && toolResult(answer(toolRefused, id: 1)) == (errorText(refused), true))
        #expect(errorText(refused).contains("9922 Hz"), "\(refused.stderr)")
        #expect(try slowTool.xml() == before.0 && DenoiseCommandTests.clips(slowTool) == before.1)
    }

    /// C12: no effect, the frequency without a sibilance, and a value past its end give an argument
    /// error with the text of the command, and change nothing.
    @Test(
        arguments: [
            ([:], "Give at least one repair: rumble, clipping, or sibilance."),
            (["sibilance_hz": 5_000], "A sibilance frequency needs a sibilance."),
            (["rumble": 301], "The argument \"rumble\" must be an integer from 20 to 300."),
            (["clipping": 89], "The argument \"clipping\" must be an integer from 90 to 100."),
            (["sibilance": 41], "The argument \"sibilance\" must be an integer from 1 to 40."),
            (
                ["sibilance": 10, "sibilance_hz": 1_999],
                "The argument \"sibilance_hz\" must be an integer from 2000 to 16000."
            ),
            (["rumble": "80"], "The argument \"rumble\" must be an integer from 20 to 300."),
        ] as [([String: any Sendable], String)])
    func badArgumentRefused(extra: [String: any Sendable], text: String) async throws {
        let package = try DenoiseCommandTests.package()
        let before = (try package.xml(), DenoiseCommandTests.clips(package))
        let arguments: [String: any Sendable] = ["package": package.path, "clips": ["c1"]]

        let answers = try await mcp([toolCall(1, "clip_repair", arguments.merging(extra) { $1 })])

        #expect(toolResult(answer(answers, id: 1)) == (text, true), "\(extra): \(answers)")
        #expect(try package.xml() == before.0 && DenoiseCommandTests.clips(package) == before.1)
    }

    /// The stop text of a long call names the repair, not the noise reduction, and the noise
    /// reduction keeps its name.
    @Test func serverStopNamesTheRender() {
        let repair = ClipRenderWork(clips: ["c1"], request: ClipRenderRequest(Treatment(.rumble(.standard))))
        let noise = ClipRenderWork(clips: ["c1"], request: ClipRenderRequest(Treatment(.noise(.standard))))
        let humOnly = ClipRenderWork(
            clips: ["c1"], request: ClipRenderRequest(Treatment(.hum(.hz50)), removing: [.noise]))

        #expect(
            serverStopMessage(.clipRender(repair))
                == "Dirigible stopped its agent server, so the repair stopped. No clip changed.")
        #expect(
            serverStopMessage(.clipRender(noise))
                == "Dirigible stopped its agent server, so the noise reduction stopped. No clip changed.")
        #expect(serverStopMessage(.clipRender(humOnly)).contains("the noise reduction stopped"))
    }
}
