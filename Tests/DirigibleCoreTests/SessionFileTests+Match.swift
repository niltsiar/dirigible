import Foundation
import Testing

@testable import DirigibleCore

/// The `<match>` element of a track at `matchSessionVersion` (decision 0074 D4, C5).
extension SessionFileTests {
    /// A `<match>` with 25 curve values of `gain` at band 0 and 0 elsewhere, and 25 target powers of
    /// `power` at band 0 and 1 elsewhere. A nil attribute is not written.
    static func matchElement(
        amount: String? = "75", bypassed: String? = nil, reference: String? = "Host 01", gain: String = "6.5",
        power: String = "0.25", curveCount: Int = 25, separator: String = " "
    ) -> String {
        let curve = ([gain] + Array(repeating: "0.0", count: curveCount - 1)).joined(separator: separator)
        let target = ([power] + Array(repeating: "1.0", count: 24)).joined(separator: " ")
        let attributes = [
            amount.map { #"amount="\#($0)""# }, reference.map { #"reference="\#($0)""# }, #"curve="\#(curve)""#,
            #"target="\#(target)""#, bypassed.map { #"bypassed="\#($0)""# },
        ]
        return "<match " + attributes.compactMap { $0 }.joined(separator: " ") + "/>"
    }

    func readMatch(_ match: String, version: Int = matchSessionVersion) throws(SessionFileError) -> Session {
        let track = #"<track id="t1" name="Host" gain="0" layout="mono">\#(match)</track>"#
        return try Session(xml: Data(document(version: String(version), tracks: track).utf8))
    }

    /// The full session with a match on "t1", a bypassed match on "t2", and none on "t3".
    func matchedSession() throws -> Session {
        var session = try fullSession()
        try session.addTrack("t3", name: "Music", layout: .mono)
        let host = try VoiceMatchTests.match(VoiceMatchTests.curve([0: 11.25, 7: -3.1, 24: 0.000123]))
        let guest = try VoiceMatchTests.match(
            VoiceMatchTests.curve([12: -12, 13: 12]), target: VoiceMatchTests.curve([4: 1e-9, 5: 3.5]), amount: 1,
            reference: "take4-1-1")
        try session.setMatch(["t1": host, "t2": guest])
        try session.setMatchBypassed(true, tracks: ["t2"])
        return session
    }

    /// C5: a session with a match and a bypassed match saves and reads back equal. Only the bypassed
    /// match writes `bypassed`, and each match writes `reference`.
    @Test func roundTrips() throws {
        let session = try matchedSession()

        try session.write(to: package)
        let read = try Session(contentsOf: package)

        #expect(read == session)
        #expect(read.track("t1")?.match?.isBypassed == false && read.track("t2")?.match?.isBypassed == true)
        #expect(read.track("t3")?.match == nil)
        let text = try String(contentsOf: sessionXML, encoding: .utf8)
        #expect(text.components(separatedBy: "<match ").count == 3, "\(text)")
        #expect(text.components(separatedBy: #"bypassed="true""#).count == 2, "\(text)")
        #expect(text.contains(#"reference="Host 01""#) && text.contains(#"reference="take4-1-1""#), "\(text)")
    }

    /// C5: a reference name with `&`, `"`, `<`, and non-ASCII text reads back equal.
    @Test func referenceNameRoundTrips() throws {
        var session = try fullSession()
        let name = #"Dani & "José" <studio> 🎙️"#
        try session.setMatch(["t1": VoiceMatchTests.match(VoiceMatchTests.flat, reference: name)])

        let read = try Session(xml: try session.checkedData())

        #expect(read == session && read.track("t1")?.match?.reference == name)
    }

    /// C5: a session with a match writes `matchSessionVersion`, the next version after the ride.
    /// A build whose newest version is the one before refuses the file as newer (0024 P3).
    @Test func writesTheNextVersion() throws {
        let data = try matchedSession().checkedData()
        let text = String(decoding: data, as: UTF8.self)

        #expect(matchSessionVersion == rideSessionVersion + 1 && sessionVersion == matchSessionVersion)
        #expect(text.contains(#"version="\#(matchSessionVersion)""#), "\(text)")
        #expect(throws: SessionFileError.unsupportedVersion(matchSessionVersion)) {
            try Session(xml: data, newest: matchSessionVersion - 1)
        }
    }

    /// C5 and 0024 P6: a session with no match writes its old version and no `<match>`, and after
    /// Remove of its last match it writes the same bytes as before the match.
    @Test func noMatchWritesTheOldVersion() throws {
        var session = try fullSession()
        try session.setRole(.dialogue, tracks: ["t1"])
        let before = try session.checkedData()
        let text = String(decoding: before, as: UTF8.self)
        #expect(text.contains(#"version="11""#) && !text.contains("match"), "\(text)")

        try session.setMatch(["t1": VoiceMatchTests.match(VoiceMatchTests.flat)])
        #expect(session.fileVersion == matchSessionVersion)
        try session.removeMatch(tracks: ["t1"])

        let after = try session.checkedData()
        #expect(session.fileVersion == 11 && after == before)
    }

    /// C5: each bad value is refused with its attribute, and the near value reads.
    @Test func refusals() throws {
        let invalid = { (attribute: String) in SessionFileError.invalidValue(element: "match", attribute: attribute) }
        let cases: [(bad: String, error: SessionFileError, good: String)] = [
            (Self.matchElement(curveCount: 24), invalid("curve"), Self.matchElement(curveCount: 25)),
            (Self.matchElement(separator: "  "), invalid("curve"), Self.matchElement(separator: " ")),
            (Self.matchElement(gain: "12.01"), invalid("curve"), Self.matchElement(gain: "12.0")),
            (Self.matchElement(gain: "-12.01"), invalid("curve"), Self.matchElement(gain: "-12")),
            (Self.matchElement(gain: "nan"), invalid("curve"), Self.matchElement(gain: "1e-3")),
            (Self.matchElement(power: "-1"), invalid("target"), Self.matchElement(power: "0")),
            (Self.matchElement(power: "nan"), invalid("target"), Self.matchElement(power: "0.0")),
            (Self.matchElement(power: "inf"), invalid("target"), Self.matchElement(power: "1e300")),
            (Self.matchElement(amount: "0"), invalid("amount"), Self.matchElement(amount: "1")),
            (Self.matchElement(amount: "101"), invalid("amount"), Self.matchElement(amount: "100")),
            (Self.matchElement(amount: "75.0"), invalid("amount"), Self.matchElement(amount: "75")),
            (Self.matchElement(bypassed: "1"), invalid("bypassed"), Self.matchElement(bypassed: "true")),
            (
                Self.matchElement(reference: nil), .missingAttribute(element: "match", attribute: "reference"),
                Self.matchElement(reference: "Host 01")
            ),
            (
                Self.matchElement(amount: nil), .missingAttribute(element: "match", attribute: "amount"),
                Self.matchElement()
            ),
            (Self.matchElement() + Self.matchElement(), invalid("count"), Self.matchElement()),
        ]
        for (bad, error, good) in cases {
            #expect(throws: error, "\(bad)") { try readMatch(bad) }
            #expect(try readMatch(good).track("t1")?.match != nil, "\(good)")
        }
        #expect(throws: invalid("version"), "a match in a file of the version before") {
            try readMatch(Self.matchElement(), version: matchSessionVersion - 1)
        }
        let read = try #require(
            try readMatch(Self.matchElement(bypassed: "true", gain: "12.0", power: "0")).track("t1")?.match)
        #expect(read.isBypassed && read.curve.decibels[0] == 12 && read.targetPowers[0] == 0)
        #expect(read.amount.percent == 75 && read.reference == "Host 01")
    }
}
