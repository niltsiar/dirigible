import DirigibleCore
import Foundation
import Testing

/// The tools `clip_envelope` and `clip_gain_range` on the files (decision 0060, C6 and C7). Clip
/// `c1` plays file frames 10 000..<50 000 of `f1` at timeline frame 20 000, with points at file
/// frames 5000 and 70 000 outside its window.
struct MCPEnvelopeToolTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 144_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        let points = [(5_000, -3.0), (70_000, -9)].map {
            GainEnvelope.Point(frame: Frames($0.0), gain: Gain(dB: $0.1)!)
        }
        try session.place(
            Clip(id: "c1", file: "f1", start: 20_000, offset: 10_000, length: 40_000, envelope: GainEnvelope(points)!),
            on: "t1")
        package = try TemporaryPackage(session)
    }

    private func filePoints() throws -> [[Int]] {
        try package.read().clip("c1")?.clip.envelope.points.map { [$0.frame.count, Int($0.gain.dB)] } ?? []
    }

    /// C6: a set and a clear by the tool keep the points outside the clip window, and
    /// `session_info` gives the points inside the window in timeline frames and the count outside.
    @Test func aSetKeepsThePointsOutsideTheClipWindow() async throws {
        let answers = try await mcp([
            toolCall(
                1, "clip_envelope", ["package": package.path, "clip": "c1", "points": [[30_000, -12], [20_000, 0]]]),
            toolCall(2, "session_info", ["package": package.path]),
            toolCall(3, "session_info", ["package": package.path, "compact": true]),
        ])
        #expect(toolResult(answer(answers, id: 1)) == ("OK", false))
        #expect(try filePoints() == [[5_000, -3], [10_000, 0], [20_000, -12], [70_000, -9]])
        let info = toolResult(answer(answers, id: 2)).text
        #expect(
            info.contains(#""envelope":[[20000,0],[30000,-12]]"#) && info.contains(#""pointsOutside":2"#), "\(info)")
        let compact = toolResult(answer(answers, id: 3)).text
        #expect(compact.contains(#""points":4"#) && !compact.contains("envelope"), "\(compact)")

        let cleared = try await mcp([
            toolCall(1, "clip_envelope", ["package": package.path, "clip": "c1", "points": [[Any]]()])
        ])
        #expect(toolResult(answer(cleared, id: 1)) == ("OK", false))
        #expect(try filePoints() == [[5_000, -3], [70_000, -9]])
    }

    /// The tool refuses a point that is not a pair of a frame and a gain, a frame given twice, and a
    /// range gain with `from` not less than `to` or a ramp under 1 or over 2^40, with no edit.
    @Test func aBadArgumentIsRefused() async throws {
        let before = try package.xml()
        let pairs = "an array of [frame, dB] pairs, each frame 0 or more and each gain from -96 to 96"
        let cases: [(String, [String: Any], String)] = [
            ("clip_envelope", ["clip": "c1", "points": [[20_000]]], "The argument \"points\" must be \(pairs)."),
            ("clip_envelope", ["clip": "c1", "points": [[-1, 0]]], "The argument \"points\" must be \(pairs)."),
            ("clip_envelope", ["clip": "c1", "points": [[20_000, 0], [20_000, -3]]], "Frame 20000 is given twice."),
            ("clip_gain_range", ["track": ["t1"], "from": 5, "to": 5, "db": 1], "from must be less than to."),
            (
                "clip_gain_range", ["track": ["t1"], "from": 0, "to": 5, "db": 1, "ramp": 0],
                "The argument \"ramp\" must be an integer, 1 or more."
            ),
            (
                "clip_gain_range", ["track": ["t1"], "from": 0, "to": 5, "db": 1, "ramp": Frames.limit.count + 1],
                "a frame is negative or more than 2^40."
            ),
        ]
        let answers = try await mcp(
            cases.enumerated().map { toolCall($0 + 1, $1.0, $1.1.merging(["package": package.path]) { $1 }) })
        for (index, (_, _, text)) in cases.enumerated() {
            #expect(toolResult(answer(answers, id: index + 1)) == (text, true))
        }
        #expect(try package.xml() == before)
    }
}
