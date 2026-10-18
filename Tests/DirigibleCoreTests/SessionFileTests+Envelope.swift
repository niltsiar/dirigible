import Foundation
import Testing

@testable import DirigibleCore

/// The gain envelope in `session.xml` version 10 (decision 0060, C4).
extension SessionFileTests {
    /// File "f1" of 1 000 frames; clip "c1" plays file frames 100 ..< 600.
    func readEnvelope(_ version: String, _ points: String, newest: Int = sessionVersion) throws(SessionFileError)
        -> Session
    {
        let file = #"<file id="f1" path="a.wav" channels="1" length="1000"/>"#
        let track =
            #"<track id="t1" name="A" gain="0" layout="mono"><clip id="c1" file="f1" start="0" offset="100" length="500" gain="0"><envelope>\#(points)</envelope></clip></track>"#
        return try Session(xml: Data(document(version: version, files: file, tracks: track).utf8), newest: newest)
    }

    static func envelopeSession(_ points: GainEnvelope) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "a.wav", layout: .mono, length: 1_000))
        try session.addTrack("t1", name: "A", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 100, length: 500, envelope: points), on: "t1")
        return session
    }

    /// 0024 P6: a session with no point writes no `<envelope>` and keeps its version.
    @Test func aSessionWithNoPointKeepsItsVersion() throws {
        let session = try Self.envelopeSession(.empty)
        let text = String(decoding: try session.checkedData(), as: UTF8.self)
        #expect(session.fileVersion == 1 && text.contains(#"version="1""#) && !text.contains("envelope"))
    }

    /// C4: one point gives version 10, and the envelope reads back equal, a point outside the clip
    /// window too. A build whose newest version is 9 refuses the file as newer.
    @Test func aSessionWithAnEnvelopeWritesVersion10() throws {
        let session = try Self.envelopeSession(envelope([(0, -3), (350, -16.25), (1_000, 6)]))
        let data = try session.checkedData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(session.fileVersion == 10 && text.contains(#"version="10""#))
        #expect(text.contains(#"<point frame="350" gain="-16.25"></point>"#), "the point text")
        #expect(try Session(xml: data) == session, "the envelope reads back equal")
        #expect(throws: SessionFileError.unsupportedVersion(10), "a version 9 build") {
            try Session(xml: data, newest: 9)
        }
    }

    /// C4: `<envelope>` in a file of version 9 is damaged. The same file as version 10 reads.
    @Test func aVersion9FileWithAnEnvelopeIsRefused() throws {
        let point = #"<point frame="200" gain="-6"/>"#
        #expect(throws: SessionFileError.invalidValue(element: "envelope", attribute: "version")) {
            try readEnvelope("9", point)
        }
        let read = try readEnvelope("10", point)
        #expect(read.clip("c1")?.clip.envelope == envelope([(200, -6)]), "the control reads")
    }

    /// C4: a negative frame, frames that do not ascend, a gain that is not finite, and a frame
    /// after the end of the file are damaged. A point at the file end and a point outside the clip
    /// window read, and a gain outside `Gain.range` clamps.
    @Test func aDamagedEnvelopeIsRefused() throws {
        let cases: [(name: String, points: String, error: SessionFileError)] = [
            ("a negative frame", #"<point frame="-1" gain="0"/>"#, .invalidValue(element: "point", attribute: "frame")),
            (
                "two points on one frame", #"<point frame="10" gain="0"/><point frame="10" gain="-3"/>"#,
                .invalidValue(element: "point", attribute: "frame")
            ),
            (
                "descending frames", #"<point frame="20" gain="0"/><point frame="10" gain="-3"/>"#,
                .invalidValue(element: "point", attribute: "frame")
            ),
            ("a NaN gain", #"<point frame="10" gain="nan"/>"#, .invalidValue(element: "point", attribute: "gain")),
            (
                "an infinite gain", #"<point frame="10" gain="inf"/>"#,
                .invalidValue(element: "point", attribute: "gain")
            ),
            ("no gain", #"<point frame="10"/>"#, .missingAttribute(element: "point", attribute: "gain")),
            ("after the file end", #"<point frame="1001" gain="0"/>"#, .invalidSession(.clipOutsideFile("c1"))),
        ]
        for (name, points, error) in cases {
            #expect(throws: error, "\(name)") { try readEnvelope("10", points) }
        }
        let read = try readEnvelope("10", #"<point frame="0" gain="200"/><point frame="1000" gain="-3"/>"#)
        #expect(read.clip("c1")?.clip.envelope == envelope([(0, 96), (1_000, -3)]), "outside the window, clamped")
    }
}
