import Foundation
import Testing

@testable import DirigibleCore

/// Mute and solo (decision 0039): the audible rule, the setters, the heard tracks, and the
/// `session.xml` version 5 attributes.
struct TrackMuteSoloTests {
    let package = FileManager.default.temporaryDirectory
        .appending(path: "TrackMuteSoloTests-\(UUID().uuidString)/Episode.dirigible")

    func twoTracks() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        return session
    }

    /// C1: no flag, a mute, a solo, two solos (solos add), and a mute with a solo (mute wins).
    @Test func theAudibleRuleCoversEachFlagCombination() throws {
        let cases: [(muted: [TrackID], soloed: [TrackID], audible: [Bool], name: String)] = [
            ([], [], [true, true], "no flag"),
            (["t1"], [], [false, true], "t1 muted"),
            ([], ["t2"], [false, true], "t2 soloed"),
            ([], ["t1", "t2"], [true, true], "solos add"),
            (["t1"], ["t1"], [false, false], "mute wins over solo; the solo still holds t2"),
        ]
        for row in cases {
            var session = try twoTracks()
            try session.setMuted(true, tracks: row.muted)
            try session.setSoloed(true, tracks: row.soloed)
            let audible = [session.isAudible("t1"), session.isAudible("t2")]
            #expect(audible == row.audible, "audible rule: \(row.name)")
        }
    }

    /// The setters set and clear each flag; an unknown track throws and changes nothing.
    @Test func theSettersSetAndClearAndRefuseAnUnknownTrack() throws {
        var session = try twoTracks()
        try session.setMuted(true, tracks: ["t1", "t2"])
        try session.setSoloed(true, tracks: ["t2"])
        #expect(session.tracks.map(\.isMuted) == [true, true])
        #expect(session.tracks.map(\.isSoloed) == [false, true])
        try session.setMuted(false, tracks: ["t2"])
        #expect(session.tracks.map(\.isMuted) == [true, false])

        let before = session
        #expect(throws: SessionError.unknownTrack("t9")) { try session.setMuted(false, tracks: ["t1", "t9"]) }
        #expect(throws: SessionError.unknownTrack("t9")) { try session.setSoloed(true, tracks: ["t1", "t9"]) }
        #expect(session == before, "a refused setter changes no track")
    }

    /// C2b: the one filter of the mix: in the set (nil: all), audible, in session order.
    @Test func heardTracksFilterBySetAndRule() throws {
        var session = try twoTracks()
        try session.addTrack("t3", name: "Music", layout: .stereo)
        #expect(session.heardTracks(in: nil).map(\.id) == ["t1", "t2", "t3"], "no flag: all tracks")
        try session.setMuted(true, tracks: ["t2"])
        #expect(session.heardTracks(in: nil).map(\.id) == ["t1", "t3"], "a muted track is not heard")
        #expect(session.heardTracks(in: ["t3", "t2"]).map(\.id) == ["t3"], "the set and the rule")
        try session.setSoloed(true, tracks: ["t3", "t1"])
        #expect(session.heardTracks(in: nil).map(\.id) == ["t1", "t3"], "the soloed tracks in session order")
        #expect(session.heardTracks(in: ["t2"]).isEmpty, "no track of the set is heard")
        try session.setMuted(true, tracks: ["t1", "t3"])
        #expect(session.heardTracks(in: nil).isEmpty, "every soloed track muted: silence, not all tracks")
    }

    /// C4 a, e: a mute and a solo write version 5 and the attributes, and read back equal.
    /// `muted="false"` in version 5 reads as not muted.
    @Test func muteAndSoloWriteVersion5AndReadBack() throws {
        var session = try twoTracks()
        try session.setMuted(true, tracks: ["t1"])
        #expect(session.fileVersion == 5, "a mute gives version 5")
        try session.setMuted(false, tracks: ["t1"])
        try session.setSoloed(true, tracks: ["t2"])
        #expect(session.fileVersion == 5, "a solo gives version 5")
        try session.setMuted(true, tracks: ["t1"])

        try session.write(to: package)

        let xml = try String(contentsOf: package.appending(path: "session.xml"), encoding: .utf8)
        #expect(xml.contains(#"<session xmlns="https://github.com/niltsiar/dirigible/session" version="5""#))
        #expect(xml.contains(#"<track id="t1" name="Host" gain="0" layout="mono" muted="true">"#), "t1 is muted")
        #expect(xml.contains(#"<track id="t2" name="Guest" gain="0" layout="mono" soloed="true">"#), "t2 is soloed")
        #expect(try Session(contentsOf: package) == session, "version 5 reads back")

        let off = document(
            version: "5", tracks: #"<track id="t1" name="A" gain="0" layout="mono" muted="false" soloed="false"/>"#)
        let read = try Session(xml: Data(off.utf8))
        #expect(read.tracks.map(\.isMuted) == [false] && read.tracks.map(\.isSoloed) == [false], "false reads as off")
    }

    /// C4 b (0024 P6): with no flag the version stays, and no flag attribute is written.
    @Test func aSessionWithNoMuteKeepsItsVersion() throws {
        var session = try twoTracks()
        try session.setMuted(true, tracks: ["t1"])
        try session.setSoloed(true, tracks: ["t2"])
        try session.setMuted(false, tracks: ["t1"])
        try session.setSoloed(false, tracks: ["t2"])
        #expect(session.fileVersion == 1, "every flag off gives version 1")
        try session.write(to: package)
        var xml = try String(contentsOf: package.appending(path: "session.xml"), encoding: .utf8)
        #expect(xml.contains(#"version="1""#) && !xml.contains("muted") && !xml.contains("soloed"), "no flag text")

        try session.setRoute(.app(bundleID: "us.zoom.xos"), track: "t1")
        try session.write(to: package)
        xml = try String(contentsOf: package.appending(path: "session.xml"), encoding: .utf8)
        #expect(xml.contains(#"version="2""#), "an app route and no flag gives version 2")
    }

    /// The tdd round-trip rule: seeded flags through the public setters, then a write and a read.
    @Test(arguments: [UInt64(1), 2, 3])
    func seededFlagsReadBack(seed: UInt64) throws {
        var random = SplitMix(seed: seed)
        var session = try twoTracks()
        try session.addTrack("t3", name: "Music", layout: .stereo)
        let ids: [TrackID] = ["t1", "t2", "t3"]
        for _ in 0..<20 {
            let picked = ids.filter { _ in Bool.random(using: &random) }
            if Bool.random(using: &random) {
                try session.setMuted(Bool.random(using: &random), tracks: picked)
            } else {
                try session.setSoloed(Bool.random(using: &random), tracks: picked)
            }
            #expect(try Session(xml: session.checkedData()) == session, "seed \(seed) reads back")
        }
    }
}
