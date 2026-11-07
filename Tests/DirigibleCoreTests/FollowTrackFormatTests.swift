import Foundation
import Testing

@testable import DirigibleCore

/// The follow flag of a track (decision 0073): the setter and the `session.xml` attribute
/// `follow="true"` from `followSessionVersion` on.
struct FollowTrackFormatTests {
    let package = FileManager.default.temporaryDirectory
        .appending(path: "FollowTrackFormatTests-\(UUID().uuidString)/Episode.dirigible")

    func twoTracks() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("host", name: "Host", layout: .mono)
        try session.addTrack("bed", name: "Bed", layout: .stereo)
        return session
    }

    func written(_ session: Session) throws -> String {
        try session.write(to: package)
        return try String(contentsOf: package.appending(path: "session.xml"), encoding: .utf8)
    }

    func file(version: Int, follow: String) -> Data {
        Data(
            document(
                version: "\(version)",
                tracks: #"<track id="bed" name="Bed" gain="0" layout="mono" follow="\#(follow)"/>"#
            ).utf8)
    }

    /// C30: a follow track writes `follow="true"` and the version of the flag, and reads back.
    @Test func aFollowTrackRoundTripsAsVersionV() throws {
        var session = try twoTracks()
        try session.setFollowTrack(true, tracks: ["bed"])

        let xml = try written(session)

        #expect(session.fileVersion == followSessionVersion)
        #expect(xml.contains(#"version="\#(followSessionVersion)""#), "\(xml)")
        #expect(xml.contains(#"<track id="bed" name="Bed" gain="0" layout="stereo" follow="true">"#), "\(xml)")
        #expect(xml.contains(#"<track id="host" name="Host" gain="0" layout="mono">"#), "host has no flag")
        let read = try Session(contentsOf: package)
        #expect(read == session)
        #expect(read.tracks.map(\.isFollowTrack) == [false, true])
    }

    /// C30 (0024 P6): with the flag off again the version is the one of the other data, and no
    /// `follow` text is written.
    @Test func aSessionWithNoFollowTrackKeepsItsVersion() throws {
        var session = try twoTracks()
        try session.setRole(.music, tracks: ["bed"])
        try session.setFollowTrack(true, tracks: ["bed", "host"])
        #expect(session.fileVersion == followSessionVersion)

        try session.setFollowTrack(false, tracks: ["bed", "host"])

        let xml = try written(session)
        #expect(session.fileVersion == 11, "a role and no follow track gives version 11")
        #expect(xml.contains(#"version="11""#) && !xml.contains("follow"), "\(xml)")
    }

    /// C30: an unknown track throws and changes nothing, also when a known track comes first.
    @Test func setFollowTrackRefusesAnUnknownTrack() throws {
        var session = try twoTracks()
        let before = session

        #expect(throws: SessionError.unknownTrack("nope")) {
            try session.setFollowTrack(true, tracks: ["bed", "nope"])
        }
        #expect(session == before)
    }

    /// C31 (0024 P7): `follow` in a file of the version before is refused; the same text at the
    /// version of the flag reads.
    @Test func anOlderFileRefusesFollow() throws {
        #expect(throws: SessionFileError.invalidValue(element: "track", attribute: "follow")) {
            try Session(xml: file(version: followSessionVersion - 1, follow: "true"))
        }
        let read = try Session(xml: file(version: followSessionVersion, follow: "true"))
        #expect(read.tracks.map(\.isFollowTrack) == [true])
    }

    /// C31: a value that is not `true` or `false` is refused.
    @Test(arguments: ["1", "yes", "TRUE", ""])
    func aFollowValueOtherThanTrueOrFalseRefuses(value: String) throws {
        #expect(throws: SessionFileError.invalidValue(element: "track", attribute: "follow")) {
            try Session(xml: file(version: followSessionVersion, follow: value))
        }
    }

    /// C31: `follow="false"` reads as off, and the next write has no `follow`.
    @Test func followFalseReadsAsOff() throws {
        let read = try Session(xml: file(version: followSessionVersion, follow: "false"))

        #expect(read.tracks.map(\.isFollowTrack) == [false])
        let xml = try written(read)
        #expect(!xml.contains("follow") && xml.contains(#"version="1""#), "\(xml)")
    }

    /// C31 (0024 P3, P4): a build that reads up to the version before refuses a file of the flag
    /// version, and the package does not change.
    @Test func anOlderBuildRefusesAVersionVFile() throws {
        var session = try twoTracks()
        try session.setFollowTrack(true, tracks: ["bed"])
        let xml = try written(session)

        #expect(throws: SessionFileError.unsupportedVersion(followSessionVersion)) {
            try Session(xml: Data(xml.utf8), newest: followSessionVersion - 1)
        }
        let after = try String(contentsOf: package.appending(path: "session.xml"), encoding: .utf8)
        #expect(after == xml)
    }
}
