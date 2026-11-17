import DirigibleCore
import Foundation
import Testing

/// `info`, `info --json`, and `session_info` show the voice match of a track (decision 0074, C15).
extension InfoCommandTests {
    /// Track `t1` has a match at 50 % with a boost of 8.4 dB and a cut of 6.2 dB, `t2` a bypassed
    /// match at 49 % with a boost and no cut, `t3` none.
    static func matched() throws -> TemporaryPackage {
        func match(_ amount: Int, bypassed: Bool, cut: Bool) throws -> VoiceMatch {
            var curve = [Double](repeating: 0, count: 25)
            curve[3] = 8.4
            if cut { curve[10] = -6.2 }
            return try VoiceMatch(
                amount: VoiceMatch.Amount(amount)!, isBypassed: bypassed, reference: "Host 01", curve: curve,
                targetPowers: [Double](repeating: 1, count: 25))
        }
        var session = Session(sampleRate: 48_000)
        for track in ["t1", "t2", "t3"] { try session.addTrack(TrackID(track), name: track, layout: .mono) }
        try session.setMatch([
            "t1": try match(50, bypassed: false, cut: true), "t2": try match(49, bypassed: true, cut: false),
        ])
        return try TemporaryPackage(session)
    }

    /// The line of a matched track ends with `match <amount> % (+B dB, -C dB)`, and `, bypassed` after
    /// it for a bypassed match. A cut of 0 reads `0.0 dB`. A track with no match has no such text.
    @Test func matchLine() async throws {
        let text = try await Self.matched().run("info", "PKG").stdout

        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains(#"track t1 "t1" mono 0.0 dB match 50 % (+4.2 dB, -3.1 dB)"#), "\(text)")
        #expect(lines.contains(#"track t2 "t2" mono 0.0 dB match 49 % (+4.1 dB, 0.0 dB), bypassed"#), "\(text)")
        #expect(lines.contains(#"track t3 "t3" mono 0.0 dB"#), "\(text)")
    }

    /// The JSON gives the amount, the reference, and the 25 gains at that amount, and `bypassed` only
    /// when it is true. `session_info` gives the same object. A track with no match has no key.
    @Test func matchJSON() async throws {
        let package = try Self.matched()

        let json = try await package.run("info", "PKG", "--json").stdout
        let answers = try await mcp([toolCall(1, "session_info", ["package": package.path])])

        for view in [json, toolResult(answer(answers, id: 1)).text] {
            let tracks = try #require(
                (try JSONSerialization.jsonObject(with: Data(view.utf8)) as? [String: Any])?["tracks"]
                    as? [[String: Any]])
            let (first, second, third) = (tracks[0]["match"], tracks[1]["match"], tracks[2]["match"])
            let one = try #require(first as? [String: Any])
            let gains = try #require(one["gains"] as? [Double])
            #expect(one["amount"] as? Int == 50 && one["reference"] as? String == "Host 01" && one["bypassed"] == nil)
            #expect(
                gains.count == 25 && abs(gains[3] - gains[0] - 4.2) < 1e-9 && abs(gains[10] - gains[0] + 3.1) < 1e-9)
            #expect((second as? [String: Any])?["bypassed"] as? Bool == true && third == nil, "\(view)")
        }
    }
}
