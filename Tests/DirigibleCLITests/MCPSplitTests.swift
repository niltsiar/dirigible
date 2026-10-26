import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The `clip_split_stereo` tool of `dirigible mcp` on the files (decisions 0049 and 0053, criterion
/// C8). The package of `SplitStereoCommandTests`; the tool and the command each get their own copy.
struct MCPSplitTests {
    /// The tracks and clips of a session, with no track ID: a new track gets a random ID.
    func shape(_ session: Session) -> [String] {
        session.tracks.map { track in
            let clips = track.clips.map { "\($0.id)@\($0.start)+\($0.length)/\($0.file)/\($0.offset)" }
            return "\(track.name) \(track.layout) \(clips)"
        }
    }

    /// C8: the tool gives the lines of the command and the same session, and the new tracks are
    /// "<name> L" and "<name> R". A refusal gives the text of the command.
    @Test func toolMatchesCommand() async throws {
        let (cli, tool) = (try SplitStereoCommandTests.package(), try SplitStereoCommandTests.package())

        let run = try await cli.run("clip", "split-stereo", "PKG", "c1", "c2")
        let answers = try await mcp([toolCall(1, "clip_split_stereo", ["package": tool.path, "clips": ["c1", "c2"]])])

        let session = try tool.read()
        let lines = try ["c1", "c2"].map { try SplitStereoCommandTests.line(of: $0, track: "Host", in: session) }
        #expect(toolResult(answer(answers, id: 1)) == (lines.joined(separator: "\n"), false), "\(answers)")
        let cliSession = try cli.read()
        #expect(run.status == 0 && shape(cliSession) == shape(session), "the tool and the command differ")
        #expect(session.tracks.map(\.name) == ["Host", "Host L", "Host R", "Guest"])
        #expect(SplitStereoCommandTests.clips(tool) == SplitStereoCommandTests.clips(cli))

        let (mono, monoTool) = (try SplitStereoCommandTests.package(), try SplitStereoCommandTests.package())
        let refused = try await mono.run("clip", "split-stereo", "PKG", "m1")
        let toolRefused = try await mcp([toolCall(1, "clip_split_stereo", ["package": monoTool.path, "clips": ["m1"]])])
        #expect(refused.status == 1 && toolResult(answer(toolRefused, id: 1)) == (errorText(refused), true))
    }

    /// C8: a cancel after the pair writer returned its WAVs removes them, as the cancel inside the
    /// writer does. The poll finds the cancel at the read of the writer after the renames
    /// (`reads` is 1), or at the read of the work after the return (2).
    @Test(arguments: [1, 2]) func cancelLeavesNoFile(readsAfterTheRename: Int) throws {
        let package = try SplitStereoCommandTests.package()
        let before = (try package.xml(), SplitStereoCommandTests.clips(package))
        let renamed = package.url.appending(path: "Clips/f1 L.wav").path
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let control = CallControl(
            token: nil, interval: .zero, send: { _ in },
            poll: { _ in
                reads.withLock { count in
                    if FileManager.default.fileExists(atPath: renamed) { count += 1 }
                    return count >= readsAfterTheRename
                }
            }, step: {})
        let work = SplitWork(clips: ["c1", "c2"])

        let thrown = #expect(throws: ToolError.self) {
            try work.run(package.url, path: package.path, control: control)
        }

        #expect(thrown?.message == "the split was cancelled.", "\(String(describing: thrown))")
        #expect(reads.withLock { $0 } == readsAfterTheRename)
        #expect(
            SplitStereoCommandTests.clips(package) == before.1,
            "the cancel left \(SplitStereoCommandTests.clips(package))")
        #expect(try package.xml() == before.0, "a cancelled split changed session.xml")
    }

    /// C8: each text of the split names the split, and none is a text of an import.
    @Test func eachSplitErrorNamesTheSplit() async throws {
        let cases: [SplitError] = [
            .space(needed: 9, free: 3), .write(file: "f1 L.wav", errno: ENOSPC),
            .sourceUnreadable(file: "f1.wav", errno: EIO), .sourceMissing(file: "f1.wav"), .cancelled,
        ]
        for error in cases { #expect(error.message.hasPrefix("the split "), "\(error.message)") }
        let imports: [ImportError] = [
            .space(file: "f1.wav", needed: 9, free: 3), .unreadable(file: "f1.wav", errno: EIO), .cancelled,
        ]
        let importTexts = Set(imports.map { ImportWork.message($0, file: "f1.wav", package: "p") })
        #expect(importTexts.isDisjoint(with: cases.map(\.message)), "a split text is an import text")
        #expect(SplitError.session(.notStereo("m1")).message == SessionError.notStereo("m1").message)

        // The tool gives the text of the error, not a text of the import.
        let package = try SplitStereoCommandTests.package()
        try FileManager.default.removeItem(at: package.url.appending(path: "Clips/f1.wav"))
        let answers = try await mcp([toolCall(1, "clip_split_stereo", ["package": package.path, "clips": ["c1"]])])
        let text = "the split cannot find the source \"f1.wav\" in Clips/."
        #expect(toolResult(answer(answers, id: 1)) == (text, true), "\(answers)")
    }
}
