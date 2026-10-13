import DirigibleCore
import Foundation
import Testing

/// The long tools of `dirigible mcp` on the files: progress and cancel (decision 0049). Each stdin
/// is a file, so the whole input is in the buffer of the server when a call starts.
struct MCPLongToolTests {
    let package: TemporaryPackage

    /// Track `t1`: clip `c1` of 1 s (`one.wav`), then clip `c2` of 3 s (`three.wav`), at 48 kHz.
    /// One block of `clipLoudness` is 65,536 frames, so `c1` is one block.
    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "one", path: "one.wav", layout: .stereo, length: 48_000))
        try session.addFile(AudioFile(id: "three", path: "three.wav", layout: .stereo, length: 144_000))
        try session.addTrack("t1", name: "Host", layout: .stereo)
        try session.place(Clip(id: "c1", file: "one", start: 0, offset: 0, length: 48_000), on: "t1")
        try session.place(Clip(id: "c2", file: "three", start: 48_000, offset: 0, length: 144_000), on: "t1")
        package = try TemporaryPackage(session)
        let clips = package.url.appending(path: "Clips")
        try LoudnessCommandTests.writeWAV(clips.appending(path: "one.wav"), seconds: 1)
        try LoudnessCommandTests.writeWAV(clips.appending(path: "three.wav"), seconds: 3)
    }

    private var loudness: [String: Any] { ["package": package.path] }
    private let expected = "c1\t-23.0 LUFS\nc2\t-23.0 LUFS"

    private func has(_ lines: [Answer], id: Int) -> Bool { lines.contains { $0["id"] as? Int == id } }

    /// The `progress` values of the notifications, in order.
    private func progress(_ lines: [Answer]) -> [Double] {
        notifications(lines).compactMap { ($0["params"] as? [String: Any])?["progress"] as? Double }
    }

    @Test func aCancelEndsTheLoudness() async throws {
        let lines = try await mcpLines([
            toolCall(2, "loudness", loudness, token: 1), cancelLine(2), modernRequest(3, "ping"),
        ])
        #expect(has(lines, id: 3), "the ping after the cancel has its answer: \(lines)")
        #expect(!has(lines, id: 2), "a cancelled call has no answer: \(lines)")
    }

    /// C20: a call whose cancel is in the buffer before it starts does not run.
    @Test func aCancelledQueuedCallDoesNotRun() async throws {
        let before = try package.xml()
        let lines = try await mcpLines([
            toolCall(2, "loudness", loudness),
            toolCall(3, "clip_gain", ["package": package.path, "clips": ["c1"], "db": 3]),
            cancelLine(3), modernRequest(4, "ping"),
        ])
        #expect(toolResult(answer(lines, id: 2)).text == expected, "the loudness before it runs")
        #expect(has(lines, id: 4), "the ping after the cancel has its answer: \(lines)")
        #expect(!has(lines, id: 3), "the cancelled clip_gain has no answer: \(lines)")
        #expect(try package.xml() == before, "the cancelled clip_gain changed session.xml")
    }

    @Test func aCancelOfAnotherIDChangesNothing() async throws {
        let lines = try await mcpLines([toolCall(2, "loudness", loudness, token: 1), cancelLine(9)])
        #expect(toolResult(answer(lines, id: 2)) == (expected, false), "a cancel of id 9 left the call of id 2")
    }

    /// C17: the fraction is the frames done over the frames of all chosen clips. `c1` is one block,
    /// so 48,000 of 192,000 frames, 25.0, is a value.
    @Test func loudnessProgressCoversAllClips() async throws {
        let lines = try await mcpLines([toolCall(2, "loudness", loudness, token: 1)])
        let values = progress(lines)
        #expect(values.contains(25), "no value of 25.0 when c1 ends: \(values)")
        #expect(values.allSatisfy { $0 < 100 }, "\(values)")
    }

    /// C2: two or more lines before the answer, with the integer token, `total` 100, and a value
    /// that grows and stays below 100.
    @Test func progressGrowsBeforeTheAnswer() async throws {
        let lines = try await mcpLines([toolCall(2, "loudness", loudness, token: 7)])
        let answerAt = try #require(lines.firstIndex { $0["id"] as? Int == 2 }, "no answer: \(lines)")
        #expect(notifications(Array(lines[answerAt...])).isEmpty, "a progress line after the answer")
        let notes = notifications(lines)
        #expect(notes.count >= 2, "\(notes)")
        for note in notes {
            let params = note["params"] as? [String: Any] ?? [:]
            #expect(note["method"] as? String == "notifications/progress", "\(note)")
            #expect(params["progressToken"] as? Int == 7 && params["total"] as? Int == 100, "\(note)")
        }
        let values = progress(lines)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 } && values.allSatisfy { $0 < 100 }, "\(values)")
        #expect(toolResult(answer(lines, id: 2)) == (expected, false))
    }

    @Test func aStringTokenKeepsItsType() async throws {
        let notes = notifications(try await mcpLines([toolCall(2, "loudness", loudness, token: "job-1")]))
        #expect(!notes.isEmpty)
        #expect(
            notes.allSatisfy { ($0["params"] as? [String: Any])?["progressToken"] as? String == "job-1" }, "\(notes)")
    }

    @Test func noTokenNoProgress() async throws {
        let lines = try await mcpLines([toolCall(2, "loudness", loudness)])
        #expect(notifications(lines).isEmpty, "\(lines)")
        #expect(toolResult(answer(lines, id: 2)) == (expected, false))
    }

    /// C5: the end of stdin does not cancel a long call.
    @Test func anEOFDoesNotCancelALoudness() async throws {
        let lines = try await mcpLines([toolCall(2, "loudness", loudness, token: 1)])
        #expect(toolResult(answer(lines, id: 2)) == (expected, false), "the call after EOF: \(lines)")
    }

    /// C13: the tool gives the stdout of `dirigible loudness`, and the error text of its refusals.
    @Test func theToolTextIsTheCommandText() async throws {
        let fixture = try LoudnessCommandTests.package()
        let missing = fixture.folder.appending(path: "Gone.dirigible").path
        let lines = try await mcp([
            toolCall(1, "loudness", ["package": fixture.path]),
            toolCall(2, "loudness", ["package": fixture.path, "clips": ["plain", "loud"]]),
            toolCall(3, "loudness", ["package": fixture.path, "clips": ["loud", "nope"]]),
            toolCall(4, "loudness", ["package": missing]),
        ])
        let cli = [
            try await fixture.run("loudness", "PKG"), try await fixture.run("loudness", "PKG", "plain", "loud"),
        ]
        for (id, run) in zip([1, 2], cli) {
            #expect(toolResult(answer(lines, id: id)) == (String(run.stdout.dropLast()), false), "id \(id)")
        }
        let refusals = [
            try await fixture.run("loudness", "PKG", "loud", "nope"), try await dirigible("loudness", missing),
        ]
        for (id, run) in zip([3, 4], refusals) {
            #expect(run.status == 2 && toolResult(answer(lines, id: id)) == (errorText(run), true), "id \(id)")
        }
    }
}
