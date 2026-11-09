import DirigibleCore
import Foundation
import Testing

/// `info`, `info --json`, and `session_info` show the ride layer of a clip as a summary, never as points
/// (criterion C21).
extension SessionViewTests {
    func points(_ pairs: [(Int, Double)]) throws -> GainEnvelope {
        try #require(GainEnvelope(pairs.map { GainEnvelope.Point(frame: Frames($0.0), gain: Gain(dB: $0.1)!) }))
    }

    /// C21. Clip `c1` plays the file frames 10 000 to 210 000. Its ride has two points inside the window and
    /// one on each side: the text, the JSON, and the compact JSON give the count inside the window and
    /// the lowest and highest gain of the window to 0.1 dB, and the manual point stays in the envelope.
    @Test func rideShowsASummary() async throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        let ride = try points([(5_000, 6), (20_000, -3.04), (150_000, 2.26), (400_000, -6)])
        let manual = try points([(50_000, -1)])
        try session.place(
            Clip(id: "c1", file: "f1", start: 0, offset: 10_000, length: 200_000, envelope: manual, ride: ride),
            on: "t1")
        let package = try TemporaryPackage(session)

        let text = try await package.run("info", "PKG").stdout
        let json = try await package.run("info", "PKG", "--json").stdout
        let compact = try await package.run("info", "PKG", "--json", "--compact").stdout
        let answers = try await mcp([toolCall(1, "session_info", ["package": package.path])])

        let line =
            "  clip c1 file f1 start 0 offset 10000 length 200000 0.0 dB envelope 40000:-1.0 ride 2 points -3.0 to 3.0 dB"
        #expect(text.split(separator: "\n").contains(Substring(line)), "\(text)")
        for view in [json, toolResult(answer(answers, id: 1)).text] {
            let clip = try Self.clip(view)
            #expect(clip["ride"] as? NSDictionary == ["points": 2, "lowest": -3, "highest": 3], "\(view)")
            #expect(clip["envelope"] != nil && clip["ridePoints"] == nil)
        }
        let small = try Self.clip(compact)
        #expect(small["ridePoints"] as? Int == 2 && small["ride"] == nil && small["points"] as? Int == 1, "\(compact)")
    }

    /// The JSON object of clip `c1` of a view.
    static func clip(_ text: String) throws -> [String: Any] {
        let view = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let tracks = try #require(view["tracks"] as? [[String: Any]])
        let clips = try #require(tracks.first?["clips"] as? [[String: Any]])
        return try #require(clips.first)
    }
}

extension InfoCommandTests {
    /// C21. A clip with 18 954 ride points adds 60 bytes or less to its line in `info` (the points
    /// themselves are 548 486 bytes).
    @Test func rideLineIsShort() async throws {
        func size(ride: GainEnvelope) async throws -> Int {
            var session = Session(sampleRate: 48_000)
            try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 40_000_000))
            try session.addTrack("t1", name: "Host", layout: .mono)
            try session.place(
                Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 40_000_000, ride: ride), on: "t1")
            let result = try await TemporaryPackage(session).run("info", "PKG")
            return result.stdout.utf8.count
        }
        let long = try #require(
            GainEnvelope(
                (0..<18_954).map { GainEnvelope.Point(frame: Frames($0 * 2_000), gain: Gain(dB: Double($0 % 13) - 6)!) }
            ))

        let (with, without) = (try await size(ride: long), try await size(ride: .empty))

        #expect(with - without > 0 && with - without <= 60, "the ride adds \(with - without) bytes")
    }
}
