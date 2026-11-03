import DirigibleCore
import Foundation
import Testing

extension InfoCommandTests {
    /// P31: the text and the JSON name a pre-roll take, and the JSON has `preRollSessionVersion`.
    /// The plain take of the fixture has no `preRoll` key.
    @Test func infoShowsAPreRollTake() async throws {
        let plain = try await dirigible("info", package.path, "--json")
        let plainRoot = try #require(try JSONSerialization.jsonObject(with: Data(plain.stdout.utf8)) as? [String: Any])
        let plainRecording = try #require(plainRoot["recording"] as? [String: Any])
        #expect(plainRecording["take"] as? Int == 2 && plainRecording["preRoll"] == nil)
        try package.edit { session in
            try session.setRecording(
                Recording(
                    take: 2, playheadFrame: 0, takeStartHostTimeNanos: 987_654_321, armedTracks: ["host"],
                    isPreRoll: true))
        }

        let text = try await dirigible("info", package.path)
        #expect(
            text.stdout.contains("recording take 2 at 0 host time 987654321 armed host pre-roll\n"), "\(text.stdout)")
        let json = try await dirigible("info", package.path, "--json")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        #expect(root["version"] as? Int == preRollSessionVersion)
        #expect((root["recording"] as? [String: Any])?["preRoll"] as? Bool == true)
    }
}
