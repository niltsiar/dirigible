import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// C12 (decision 0074 D6): a change of the voice match of a heard track crossfades the next chunk;
/// a change on a muted track steps.
extension PlayerTests {
    func matched(_ percent: Int = 75) throws -> Session {
        let amount = try #require(VoiceMatch.Amount(percent))
        let match = try VoiceMatch(
            amount: amount, reference: "Host 01", curve: (0..<25).map { -12 + Double($0) },
            targetPowers: [Double](repeating: 1, count: 25))
        var session = package.session
        try session.setMatch(["t1": match])
        return session
    }

    @Test func matchChangeCrossfades() throws {
        let old = try matched(75)
        var new = old
        try new.setMatchAmount(#require(VoiceMatch.Amount(40)), tracks: ["t1"])
        #expect(Player.mixChanged(from: old, to: new))
        #expect(Player.mixChanged(from: package.session, to: old), "a new match")
        #expect(!Player.mixChanged(from: old, to: old))
    }

    @Test func bypassChangeCrossfades() throws {
        let old = try matched()
        var new = old
        try new.setMatchBypassed(true, tracks: ["t1"])
        #expect(Player.mixChanged(from: old, to: new))
        #expect(Player.mixChanged(from: new, to: old))
    }

    @Test func mutedTrackMatchSteps() throws {
        var old = try matched(75)
        try old.setMuted(true, tracks: ["t1"])
        var new = old
        try new.setMatchAmount(#require(VoiceMatch.Amount(40)), tracks: ["t1"])
        #expect(!Player.mixChanged(from: old, to: new))
    }
}
