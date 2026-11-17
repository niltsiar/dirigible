import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The `track_match_voice` tool of `dirigible mcp` on the files (decisions 0049 and 0074). The
/// packages of `MatchVoiceCommandTests`; the tool and the command each get their own copy.
struct MCPMatchVoiceTests {
    func call(_ package: TemporaryPackage, _ arguments: [String: Any], tool: String = "track_match_voice")
        async throws -> (text: String, isError: Bool)
    {
        let answers = try await mcp([toolCall(1, tool, arguments.merging(["package": package.path]) { $1 })])
        return toolResult(answer(answers, id: 1))
    }

    /// The tool gives the lines of the command and the same session in each mode: a match with a
    /// range, a replace that keeps the amount, the amount with the bypass, and the remove.
    @Test func toolMatchesCommand() async throws {
        let (cli, tool) = (try MatchVoiceCommandTests.package(), try MatchVoiceCommandTests.package())
        let steps: [(command: [String], arguments: [String: Any])] = [
            (
                ["--reference", "R", "--from", "0", "--to", "528000", "--amount", "60", "t1", "t2"],
                ["reference": "R", "from": 0, "to": 528_000, "amount": 60, "tracks": ["t1", "t2"]]
            ),
            (["--reference", "R", "t1"], ["reference": "R", "tracks": ["t1"]]),
            (
                ["--amount", "30", "--bypass", "on", "t1", "t2"],
                ["amount": 30, "bypass": true, "tracks": ["t1", "t2"]]
            ),
            (["--bypass", "off", "t2"], ["bypass": false, "tracks": ["t2"]]),
            (["--remove", "t1", "ref"], ["remove": true, "tracks": ["t1", "ref"]]),
        ]
        for (command, arguments) in steps {
            let run = try await cli.run(["track", "match-voice", "PKG"] + command)
            let answer = try await call(tool, arguments)

            try #require(run.status == 0, "\(command): \(run)")
            #expect(answer == (String(run.stdout.dropLast()), false), "\(command): \(answer)")
            #expect(try cli.holdsTheSameSession(as: tool), "\(command): the tool and the command differ")
        }
    }

    /// Each argument that does not fit gives the text of the work, as an error, and changes nothing.
    /// The arguments are JSON text, because a test argument must be `Sendable`.
    @Test(arguments: [
        (#"{"reference": "R", "from": 0, "tracks": ["t1"]}"#, pair),
        (#"{"reference": "R", "from": 1, "to": 1, "tracks": ["t1"]}"#, pair),
        (#"{"from": 0, "to": 10, "amount": 50, "tracks": ["t1"]}"#, "from and to need reference."),
        (#"{"reference": "R", "amount": 101, "tracks": ["t1"]}"#, percent),
        (#"{"amount": 0, "tracks": ["t1"]}"#, percent),
        (
            #"{"reference": "R", "bypass": true, "tracks": ["t1"]}"#,
            "bypass does not go with reference: a new match is on."
        ),
        (
            #"{"remove": true, "amount": 50, "tracks": ["t1"]}"#,
            "remove does not go with reference, from, to, amount, or bypass."
        ),
        (#"{"tracks": ["t1"]}"#, "Give reference, amount, bypass, or remove."),
        (
            #"{"amount": 50, "tracks": []}"#,
            #"The argument "tracks" must be an array of strings with one item or more."#
        ),
        (#"{"amount": "50", "tracks": ["t1"]}"#, #"The argument "amount" must be an integer."#),
        (#"{"amount": 50, "bypass": "on", "tracks": ["t1"]}"#, #"The argument "bypass" must be true or false."#),
    ])
    func badArgumentsGiveTheirText(json: String, text: String) async throws {
        let arguments = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let package = try MatchVoiceCommandTests.package()
        let before = try package.xml()

        let answer = try await call(package, arguments)

        #expect(answer == (text, true), "\(json): \(answer)")
        #expect(try package.xml() == before)
    }

    static let pair = "from and to come together, as frames in 0...2^40 with from < to."
    static let percent = "amount is a whole percent from 1 to 100."

    /// A refusal of the library gives its exact text: too little voice names the side, a range past
    /// the clip names the clip span, and a source that is missing names the file.
    @Test func refusalsGiveTheTextOfTheLibrary() async throws {
        let package = try MatchVoiceCommandTests.package(reference: 9.9, targets: [12, 12])

        let short = try await call(package, ["reference": "R", "tracks": ["t1"]])
        #expect(short == ("the reference clip has 9 s of voice; Match Voice needs 10 s.", true), "\(short)")

        let past = try await call(package, ["reference": "R", "from": 0, "to": 475_201, "tracks": ["t1"]])
        #expect(past == ("the range must lie inside the reference clip, frames 0 to 475200.", true), "\(past)")

        let side = try MatchVoiceCommandTests.package(targets: [9.9, 12])
        let target = try await call(side, ["reference": "R", "tracks": ["t1", "t2"]])
        #expect(target == ("track t1 has 9 s of voice; Match Voice needs 10 s.", true), "\(target)")

        try FileManager.default.removeItem(at: side.url.appending(path: "Clips/t2.wav"))
        let missing = try await call(side, ["reference": "R", "tracks": ["t2"]])
        #expect(missing == ("file t2 is missing; no track changed.", true), "\(missing)")
        #expect(try side.read().track("t1")?.match == nil)
    }

    /// The tool leaves out the track of the reference clip with the line of the command.
    @Test func referenceTrackIsLeftOut() async throws {
        let package = try MatchVoiceCommandTests.package()

        let answer = try await call(package, ["reference": "R", "tracks": ["ref", "t1"]])

        let session = try package.read()
        let text = "ref: left out, the track of the reference\n" + (try MatchVoiceCommandTests.line("t1", in: session))
        #expect(answer == (text, false), "\(answer)")
        #expect(session.track("ref")?.match == nil)
    }

    /// A batch holds the amount, the bypass, and the remove as steps in one edit, and refuses a
    /// call with `reference` at its index with no step run.
    @Test func batchHoldsTheEditModes() async throws {
        let package = try MatchVoiceCommandTests.package()
        _ = try await package.run("track", "match-voice", "PKG", "--reference", "R", "t1", "t2")
        let calls: [[String: Any]] = [
            ["tool": "track_match_voice", "arguments": ["amount": 30, "tracks": ["t1"]]],
            ["tool": "track_match_voice", "arguments": ["bypass": true, "tracks": ["t1", "t2"]]],
            ["tool": "track_match_voice", "arguments": ["remove": true, "tracks": ["t2"]]],
        ]

        let answer = try await call(package, ["calls": calls], tool: "batch")

        let session = try package.read()
        #expect(!answer.isError, "\(answer)")
        #expect(answer.text.split(separator: "\n").count == 4, "\(answer.text)")
        #expect(session.track("t1")?.match?.amount.percent == 30 && session.track("t1")?.match?.isBypassed == true)
        #expect(session.track("t2")?.match == nil)

        let withReference: [String: Any] = [
            "tool": "track_match_voice", "arguments": ["reference": "R", "tracks": ["t1"]],
        ]
        let refused = try await call(package, ["calls": calls + [withReference]], tool: "batch")
        let reason = "track_match_voice cannot run in a batch: a step is an edit of session.xml only."
        #expect(
            refused == ("calls[3] track_match_voice failed, so the batch changed nothing: \(reason)", true),
            "\(refused)")
        #expect(try package.read() == session)
    }

    /// A cancel before the read, in the middle of it, and at the last check leaves the same
    /// `session.xml`: the call gets no answer and no match.
    @Test func cancelChangesNothing() throws {
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
        let work = MatchWork(
            tracks: ["t1"], mode: .set(.init(reference: "R", range: nil, amount: nil)))
        let counted = OSAllocatedUnfairLock(initialState: 0)
        let all = try MatchVoiceCommandTests.package()
        _ = try work.run(all.url, path: all.path, control: control(stopAt: .max, polls: counted))
        let last = counted.withLock { $0 }
        try #require(last > 2, "a match polled \(last) times")

        for stop in [1, last / 2, last] {
            let package = try MatchVoiceCommandTests.package()
            let before = try package.xml()
            let polls = OSAllocatedUnfairLock(initialState: 0)

            let thrown = #expect(throws: ToolError.self) {
                try work.run(package.url, path: package.path, control: control(stopAt: stop, polls: polls))
            }

            #expect(thrown?.message == cancelledMessage, "stop \(stop): \(String(describing: thrown))")
            #expect(polls.withLock { $0 } == stop, "stop \(stop): the cancel came at another poll")
            #expect(try package.xml() == before, "stop \(stop): a cancelled match changed session.xml")
        }
    }
}
