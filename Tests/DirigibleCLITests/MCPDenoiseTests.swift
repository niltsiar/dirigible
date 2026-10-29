import AudioToolbox
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The `clip_denoise` tool of `dirigible mcp` on the files (decisions 0049 and 0054, criteria C10,
/// C12, and C13). The package of `DenoiseCommandTests`; the tool and the command each get their own
/// copy.
struct MCPDenoiseTests {
    /// C12: the tool gives the lines of the command and the same session. A clip on a music track and
    /// a reduction outside 1...30 give the texts of the command and of the schema.
    @Test func toolMatchesCommand() async throws {
        let (cli, tool) = (try DenoiseCommandTests.package(), try DenoiseCommandTests.package())

        let run = try await cli.run("clip", "denoise", "PKG", "c1", "c2", "--reduction", "6")
        let answers = try await mcp([
            toolCall(1, "clip_denoise", ["package": tool.path, "clips": ["c1", "c2"], "reduction": 6])
        ])

        #expect(toolResult(answer(answers, id: 1)) == (String(run.stdout.dropLast()), false), "\(answers)")
        #expect(run.status == 0, "\(run)")
        #expect(try cli.holdsTheSameSession(as: tool), "the tool and the command differ")
        #expect(DenoiseCommandTests.clips(tool) == DenoiseCommandTests.clips(cli))

        let (music, musicTool) = (try DenoiseCommandTests.package(), try DenoiseCommandTests.package())
        let refused = try await music.run("clip", "denoise", "PKG", "m1")
        let toolRefused = try await mcp([toolCall(1, "clip_denoise", ["package": musicTool.path, "clips": ["m1"]])])
        #expect(refused.status == 1 && toolResult(answer(toolRefused, id: 1)) == (errorText(refused), true))

        let bad = try await mcp([
            toolCall(1, "clip_denoise", ["package": tool.path, "clips": ["c1"], "reduction": 31])
        ])
        let text = "The argument \"reduction\" must be an integer from 1 to 30."
        #expect(toolResult(answer(bad, id: 1)) == (text, true), "\(bad)")
    }

    /// C20: `hum` with `noise` false gives the lines and the session of `--hum --no-noise`, also
    /// for a clip on a music track.
    @Test func humMatchesCommand() async throws {
        let (cli, tool) = (try DenoiseCommandTests.package(), try DenoiseCommandTests.package())

        let run = try await cli.run("clip", "denoise", "PKG", "c1", "m1", "--hum", "50", "--no-noise")
        let answers = try await mcp([
            toolCall(1, "clip_denoise", ["package": tool.path, "clips": ["c1", "m1"], "hum": 50, "noise": false])
        ])

        try #require(run.status == 0, "\(run)")
        #expect(toolResult(answer(answers, id: 1)) == (String(run.stdout.dropLast()), false), "\(answers)")
        #expect(try cli.holdsTheSameSession(as: tool), "the tool and the command differ")
        #expect(DenoiseCommandTests.clips(tool) == DenoiseCommandTests.clips(cli))
        #expect(try DenoiseCommandTests.played("c1", in: tool).path == "f1 HR.wav")
    }

    /// C20: a hum that is not 50 or 60, `noise` false with no hum, and a reduction with `noise`
    /// false give an argument error and change nothing.
    @Test(
        arguments: [
            (["hum": 55], "The argument \"hum\" must be an integer, 50 or 60."),
            (["hum": "50"], "The argument \"hum\" must be an integer, 50 or 60."),
            (["noise": false], "Give a hum of 50 or 60 when the noise reduction is off."),
            (["hum": 50, "noise": false, "reduction": 6], "A reduction needs the noise reduction on."),
            (["hum": 50, "noise": "no"], "The argument \"noise\" must be true or false."),
        ] as [([String: any Sendable], String)])
    func badHumArgumentRefused(extra: [String: any Sendable], text: String) async throws {
        let package = try DenoiseCommandTests.package()
        let before = (try package.xml(), DenoiseCommandTests.clips(package))
        let arguments: [String: any Sendable] = ["package": package.path, "clips": ["c1"]]

        let answers = try await mcp([toolCall(1, "clip_denoise", arguments.merging(extra) { $1 })])

        #expect(toolResult(answer(answers, id: 1)) == (text, true), "\(extra): \(answers)")
        #expect(try package.xml() == before.0 && DenoiseCommandTests.clips(package) == before.1)
    }

    /// C5: the amount of the level again gives "Nothing to change." and writes no file and no
    /// `session.xml`.
    @Test func equalAmountWritesNothing() async throws {
        let package = try DenoiseCommandTests.package()
        let call = toolCall(1, "clip_denoise", ["package": package.path, "clips": ["c1"], "reduction": 12])
        let first = try await mcp([call])
        try #require(toolResult(answer(first, id: 1)).1 == false, "\(first)")
        let before = (try package.xml(), DenoiseCommandTests.clips(package))

        let again = try await mcp([call])

        #expect(toolResult(answer(again, id: 1)) == ("Nothing to change.", false), "\(again)")
        #expect(try package.xml() == before.0 && DenoiseCommandTests.clips(package) == before.1)
    }

    /// C13: the tool gives the role refusal for a clip that needs no render: `m1` is reduced on a
    /// voice track, and then its track gets the music role.
    @Test func unchangedMusicClipIsRefused() async throws {
        let package = try DenoiseCommandTests.package(bedRole: .dialogue)
        let call = toolCall(1, "clip_denoise", ["package": package.path, "clips": ["m1"]])
        let first = try await mcp([call])
        try #require(toolResult(answer(first, id: 1)).1 == false, "\(first)")
        let role = try await package.run("track", "role", "PKG", "t2", "music")
        try #require(role.status == 0, "\(role)")
        let before = (try package.xml(), DenoiseCommandTests.clips(package))

        let again = try await mcp([call])

        let text = ClipRenderError.trackRole(clip: "m1", role: .music).message
        #expect(toolResult(answer(again, id: 1)) == (text, true), "\(again)")
        #expect(try package.xml() == before.0 && DenoiseCommandTests.clips(package) == before.1)
    }

    /// The tool text and the command help limit the render again from the source to a clip that
    /// this version reduced: a clip that an older version reduced has no link (decision 0057).
    @Test func eachTextSaysThatAnOlderClipIsReducedAgain() async throws {
        let answers = try await mcp([modernRequest(1, "tools/list")])
        let tools = result(answer(answers, id: 1))["tools"] as? [[String: Any]] ?? []
        let tool = tools.first { $0["name"] as? String == "clip_denoise" }?["description"] as? String ?? ""
        let help = try await dirigible("clip", "denoise", "--help")
        for (name, text) in ["tool": tool, "help": help.stdout] {
            let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            #expect(
                words.contains("a clip that this version reduced")
                    && words.contains("A clip that an older version reduced has no link"), "\(name): \(words)")
        }
    }

    /// C12: a cancel before the render, after its renames, and after its return leaves no new WAV and
    /// the same `session.xml`. The poll finds the cancel at the first read (`readsAfterTheRename` 0),
    /// at the read of `renderClips` after the renames (1), or at the read of the work after the
    /// return (2).
    @Test(arguments: [0, 1, 2]) func cancelWritesNothing(readsAfterTheRename: Int) throws {
        let package = try DenoiseCommandTests.package()
        let before = (try package.xml(), DenoiseCommandTests.clips(package))
        let renamed = package.url.appending(path: "Clips/f1 NR.wav").path
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let control = CallControl(
            token: nil, interval: .zero, send: { _ in },
            poll: { _ in
                reads.withLock { count in
                    if readsAfterTheRename == 0 { return true }
                    if FileManager.default.fileExists(atPath: renamed) { count += 1 }
                    return count >= readsAfterTheRename
                }
            }, step: {})
        let work = ClipRenderWork(clips: ["c1", "c2"], request: ClipRenderRequest(Treatment(.noise(.standard))))

        let thrown = #expect(throws: ToolError.self) {
            try work.run(package.url, path: package.path, control: control)
        }

        #expect(thrown?.message == "the clip render was cancelled.", "\(String(describing: thrown))")
        #expect(reads.withLock { $0 } == readsAfterTheRename, "the cancel came at another read")
        #expect(DenoiseCommandTests.clips(package) == before.1, "the cancel left \(DenoiseCommandTests.clips(package))")
        #expect(try package.xml() == before.0, "a cancelled render changed session.xml")
    }

    /// C10: each text of the render names the clip render, or the noise reduction for the two cases of
    /// the unit and the role, and none is a text of an import. The text of a role refusal names the
    /// clip and the role.
    @Test func eachRenderErrorNamesTheRender() {
        let cases: [ClipRenderError] = [
            .space(needed: 9, free: 3), .write(file: "f1 NR.wav", errno: ENOSPC),
            .sourceUnreadable(file: "f1.wav", errno: EIO), .sourceMissing(file: "f1.wav"),
            .notDownloaded(file: "f1.wav"), .cancelled, .trackRole(clip: "m1", role: .music),
            .trackRole(clip: "e1", role: .effects), .effectUnavailable(status: -3000), .engine(status: -50),
            .mixedTreatments(clips: ["a", "b"]), .stillOverFullScale(file: "Clips/f1 NR.wav"),
        ]
        for error in cases {
            let name =
                switch error {
                case .effectUnavailable, .trackRole: "the noise reduction "
                default: "the clip render "
                }
            #expect(error.message.hasPrefix(name), "\(error.message)")
        }
        let imports: [ImportError] = [
            .space(file: "f1.wav", needed: 9, free: 3), .unreadable(file: "f1.wav", errno: EIO), .cancelled,
        ]
        let importTexts = Set(imports.map { ImportWork.message($0, file: "f1.wav", package: "p") })
        #expect(importTexts.isDisjoint(with: cases.map(\.message)), "a render text is an import text")
        #expect(ClipRenderError.session(.unknownClip("zz")).message == SessionError.unknownClip("zz").message)
        let role = ClipRenderError.trackRole(clip: "m1", role: .music).message
        #expect(role.contains("\"m1\"") && role.contains("music"), Comment(rawValue: role))
    }

    /// C10: a unit that does not load gives the status in a text of the render and writes no file.
    @Test func unavailableNamesTheCause() throws {
        let package = try DenoiseCommandTests.package()
        let before = (try package.xml(), DenoiseCommandTests.clips(package))
        var work = ClipRenderWork(clips: ["c1"], request: ClipRenderRequest(Treatment(.noise(.standard))))
        work.component = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: 0x6E6F_6E65, componentManufacturer: 0,
            componentFlags: 0, componentFlagsMask: 0)
        let control = CallControl(token: nil, interval: .zero, send: { _ in }, poll: { _ in false }, step: {})

        let thrown = #expect(throws: ToolError.self) {
            try work.run(package.url, path: package.path, control: control)
        }

        let text = "the noise reduction of macOS (AUSoundIsolation) did not load (status -3000)."
        #expect(thrown?.message == text, "\(String(describing: thrown))")
        #expect(DenoiseCommandTests.clips(package) == before.1)
        #expect(try package.xml() == before.0)
    }
}
