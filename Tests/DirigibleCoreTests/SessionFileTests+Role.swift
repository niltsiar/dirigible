import Foundation
import Testing

@testable import DirigibleCore

/// The track role in `session.xml` version 11 (decision 0060, C13).
extension SessionFileTests {
    func readRole(_ version: String, _ role: String, newest: Int = sessionVersion) throws(SessionFileError) -> Session {
        let track = #"<track id="t1" name="Bed" gain="0" layout="stereo" role="\#(role)"/>"#
        return try Session(xml: Data(document(version: version, tracks: track).utf8), newest: newest)
    }

    /// C13: a role reads, and a save writes it as version 11. A build whose newest version is 10
    /// refuses the saved file as newer.
    @Test func aSessionWithARoleWritesVersion11() throws {
        let data = try readRole("11", "music").checkedData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#"version="11""#) && text.contains(#"layout="stereo" role="music""#), "\(text)")
        #expect(throws: SessionFileError.unsupportedVersion(11), "a version 10 build") {
            try Session(xml: data, newest: 10)
        }
    }

    /// C13: `role` in a file of version 10 is damaged, and so is a word that is not a role. The
    /// same role as version 11 reads.
    @Test func aRoleInAVersion10FileOrAnUnknownRoleIsRefused() throws {
        let error = SessionFileError.invalidValue(element: "track", attribute: "role")
        #expect(throws: error, "version 10") { try readRole("10", "music") }
        #expect(throws: error, "an unknown word") { try readRole("11", "voice") }
        #expect(throws: error, "a capital letter") { try readRole("11", "Music") }
        let read = String(decoding: try readRole("11", "effects").checkedData(), as: UTF8.self)
        #expect(read.contains(#"role="effects""#), "the control reads")
    }

    /// Seeded round trip: each track keeps its role or its lack of one through a write and a read,
    /// and the file is version 11 only when a track has a role (0024 P6).
    @Test func rolesRoundTripAndSetTheVersion() throws {
        var random = SplitMix(seed: 60_011)
        let words = ["dialogue", "music", "effects", nil]
        for _ in 0..<40 {
            let roles = (0..<Int.random(in: 1...5, using: &random)).map { _ in words.randomElement(using: &random)! }
            let tracks = roles.enumerated().map { index, role in
                let attribute = role.map { #" role="\#($0)""# } ?? ""
                return #"<track id="t\#(index)" name="T" gain="0" layout="mono"\#(attribute)/>"#
            }.joined()
            let read = try Session(xml: Data(document(version: "11", tracks: tracks).utf8))
            let data = try read.checkedData()
            let text = String(decoding: data, as: UTF8.self)
            let version = roles.contains { $0 != nil } ? "11" : "1"
            #expect(text.contains(#"version="\#(version)""#), "\(roles): \(text)")
            for (index, role) in roles.enumerated() {
                let written =
                    text.firstMatch(of: try Regex(#"<track id="t\#(index)"[^>]*>"#)).map { String($0.0) } ?? ""
                #expect(written.contains("role") == (role != nil), "\(index) in \(roles)")
                if let role { #expect(written.contains(#"role="\#(role)""#), "\(index) in \(roles)") }
            }
            #expect(try Session(xml: data) == read, "\(roles)")
        }
    }
}
