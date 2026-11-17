import Foundation
import Testing

@testable import DirigibleCore

/// The edits of the voice match of a track (decision 0074, C5 and C11): each is one call, and a
/// throw changes nothing.
struct SessionMatchTests {
    let host = try! VoiceMatchTests.match(VoiceMatchTests.curve([3: 6, 20: -4]))
    let guest = try! VoiceMatchTests.match(VoiceMatchTests.curve([9: -2]), amount: 40, reference: "Guest")

    /// The mono tracks "a" and "b", and the stereo track "s" with the clip "S" of the stereo file "f".
    func session() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("a", name: "Host", layout: .mono)
        try session.addTrack("b", name: "Guest", layout: .mono)
        try session.addTrack("s", name: "Call", layout: .stereo)
        try session.addFile(AudioFile(id: "f", path: "call.wav", layout: .stereo, length: 2_000_000))
        try session.place(Clip(id: "S", file: "f", start: 0, offset: 0, length: 1_000_000), on: "s")
        return session
    }

    /// One call gives each named track its own match. An unknown track throws and changes nothing.
    @Test func setMatchSetsEachTrack() throws {
        var session = try session()
        try session.setMatch(["a": host, "b": guest])
        #expect(session.track("a")?.match == host && session.track("b")?.match == guest)
        #expect(session.track("s")?.match == nil)

        let before = session
        #expect(throws: SessionError.unknownTrack("x")) { try session.setMatch(["s": host, "x": guest]) }
        #expect(session == before)
    }

    /// The amount changes and the curve, the bypass, and the name stay. A track with no match in the
    /// list throws `noMatch` and changes nothing, also on the matched tracks of the list.
    @Test func setMatchAmountNeedsAMatch() throws {
        var session = try session()
        try session.setMatch(["a": host, "b": guest])
        let amount = try #require(VoiceMatch.Amount(40))
        try session.setMatchAmount(amount, tracks: ["a"])
        let changed = try #require(session.track("a")?.match)
        #expect(changed.amount == amount && changed.curve == host.curve && changed.reference == host.reference)
        #expect(changed.targetPowers == host.targetPowers && changed.isBypassed == host.isBypassed)

        let before = session
        #expect(throws: SessionError.noMatch("s")) {
            try session.setMatchAmount(VoiceMatch.defaultAmount, tracks: ["a", "s"])
        }
        #expect(session == before)
    }

    /// The bypass changes and every other value stays. A track with no match throws `noMatch` and
    /// changes nothing.
    @Test func setMatchBypassedNeedsAMatch() throws {
        var session = try session()
        try session.setMatch(["a": host, "b": guest])
        try session.setMatchBypassed(true, tracks: ["a", "b"])
        #expect(session.track("a")?.match?.isBypassed == true && session.track("b")?.match?.isBypassed == true)
        #expect(session.track("a")?.match?.amount == host.amount && session.track("b")?.match?.curve == guest.curve)
        try session.setMatchBypassed(false, tracks: ["b"])
        #expect(session.track("b")?.match == guest)

        let before = session
        #expect(throws: SessionError.noMatch("s")) { try session.setMatchBypassed(true, tracks: ["b", "s"]) }
        #expect(session == before)
    }

    /// Remove clears the match of each named track; a track with no match stays as it is.
    @Test func removeMatchClearsTheTracks() throws {
        var session = try session()
        try session.setMatch(["a": host, "b": guest])
        try session.removeMatch(tracks: ["a", "s"])
        #expect(session.track("a")?.match == nil && session.track("b")?.match == guest)
        #expect(throws: SessionError.unknownTrack("x")) { try session.removeMatch(tracks: ["b", "x"]) }
        #expect(session.track("b")?.match == guest)
    }

    /// C5: Split Stereo to Mono gives each mono track the match of its stereo source.
    @Test func splitKeepsTheMatch() throws {
        var session = try session()
        try session.setMatch(["s": guest])
        try session.setMatchBypassed(true, tracks: ["s"])
        let runs = try session.clipRuns(of: ["S"])
        let pairs = runs.map { MonoPair(run: $0, leftStem: "call L", rightStem: "call R") }

        let part = try #require(try session.splitStereo(pairs, names: ("L", "R")).first)

        let source = try #require(session.track("s")?.match)
        #expect(source.isBypassed && source.curve == guest.curve)
        #expect(session.track(part.leftTrack)?.match == source && session.track(part.rightTrack)?.match == source)
    }

    /// The clip name that a match stores as its reference: the path of the file of the clip with no
    /// ".wav", else the file ID when the file is not in the pool.
    @Test func nameOfAClipIsItsFilePath() throws {
        let session = try session()
        let clip = try #require(session.clip("S")?.clip)
        #expect(session.name(of: clip) == "call")
        let orphan = Clip(id: "O", file: "take4-1-1", start: 0, offset: 0, length: 10)
        #expect(session.name(of: orphan) == "take4-1-1")
    }
}
