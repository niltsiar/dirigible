import Foundation
import Testing

@testable import DirigibleCore

/// The files that the session reader refuses.
extension SessionFileTests {
    /// Fades C3: the reader refuses each bad fade, and reads a missing one as 0.
    @Test func fadeRefusals() throws {
        let file = #"<file id="f1" path="a.wav" channels="1" length="1000"/>"#
        func clip(_ fades: String) -> String {
            #"<track id="t1" name="A" gain="0" layout="mono"><clip id="c1" file="f1" start="0" offset="0" length="1000" gain="0" \#(fades)/></track>"#
        }
        func read(_ version: String, _ fades: String, newest: Int = sessionVersion) throws(SessionFileError)
            -> Session
        {
            try Session(xml: Data(document(version: version, files: file, tracks: clip(fades)).utf8), newest: newest)
        }

        #expect(throws: SessionFileError.unsupportedVersion(3), "a: a version 2 build refuses version 3") {
            try read("3", #"fadeIn="10""#, newest: 2)
        }
        #expect(
            throws: SessionFileError.invalidValue(element: "clip", attribute: "fadeIn"),
            "b: a version 2 file with fadeIn is refused"
        ) { try read("2", #"fadeIn="10""#) }
        #expect(
            throws: SessionFileError.invalidValue(element: "clip", attribute: "fadeOut"),
            "b: a version 1 file with fadeOut is refused"
        ) { try read("1", #"fadeOut="10""#) }
        let missing = try? read("3", #"fadeIn="10""#)
        #expect(
            missing?.tracks.first?.clips.first?.fades == Fades(fadeIn: 10, fadeOut: 0),
            "c: a missing fadeOut reads 0")
        #expect(
            throws: SessionFileError.invalidSession(.fadeOutsideClip("c1", length: 1000)),
            "d: fadeIn + fadeOut = length + 1 is refused"
        ) { try read("3", #"fadeIn="500" fadeOut="501""#) }
        let full = try? read("3", #"fadeIn="500" fadeOut="500""#)
        #expect(full?.tracks.first?.clips.first?.fades == Fades(fadeIn: 500, fadeOut: 500), "d: = length reads")
        #expect(
            throws: SessionFileError.invalidValue(element: "clip", attribute: "fadeIn"),
            "e: a negative fadeIn is refused"
        ) { try read("3", #"fadeIn="-1""#) }
        #expect(
            throws: SessionFileError.invalidValue(element: "clip", attribute: "fadeOut"),
            "e: a negative fadeOut is refused"
        ) { try read("3", #"fadeOut="-1""#) }
        #expect(
            throws: SessionFileError.invalidValue(element: "clip", attribute: "fadeIn"),
            "e: a fadeIn that is not an integer is refused"
        ) { try read("3", #"fadeIn="1.5""#) }
    }

    /// Mute and solo C4 d: a version 4 file with `muted` or `soloed` is refused, and so is a
    /// value that is not `true` or `false`.
    @Test func aVersion4FileWithMutedIsRefused() throws {
        func read(_ version: String, _ flags: String) throws(SessionFileError) -> Session {
            let track = #"<track id="t1" name="A" gain="0" layout="mono" \#(flags)/>"#
            return try Session(xml: Data(document(version: version, tracks: track).utf8))
        }
        #expect(throws: SessionFileError.invalidValue(element: "track", attribute: "muted"), "muted in version 4") {
            try read("4", #"muted="true""#)
        }
        #expect(throws: SessionFileError.invalidValue(element: "track", attribute: "soloed"), "soloed in version 4") {
            try read("4", #"soloed="true""#)
        }
        #expect(throws: SessionFileError.invalidValue(element: "track", attribute: "muted"), "muted=\"yes\"") {
            try read("5", #"muted="yes""#)
        }
        let read5 = try? read("5", #"muted="true""#)
        #expect(read5?.tracks.first?.isMuted == true, "control: muted in version 5 reads")
    }

    /// Mute and solo C4 c (0024 P3): a build of version 4 refuses a version 5 file.
    @Test func aBuildOfVersion4RefusesVersion5() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setMuted(true, tracks: ["t1"])
        let data = try session.checkedData()
        #expect(throws: SessionFileError.unsupportedVersion(5)) { try Session(xml: data, newest: 4) }
        #expect(try Session(xml: data) == session, "control: the current reader reads it")
    }

    /// Crossfades F1: the reader refuses each bad crossfade, and reads a written 0 as none.
    @Test func theReaderRefusesEachBadCrossfade() throws {
        let files =
            #"<file id="fa" path="a.wav" channels="1" length="10000"/><file id="fb" path="b.wav" channels="1" length="10000"/>"#
        func read(
            _ version: String, a: String, b: String, bFile: String = "fb", bOffset: Int = 1_000, bGain: String = "0",
            newest: Int = sessionVersion
        ) throws(SessionFileError) -> Session {
            let tracks = """
                <track id="t1" name="A" gain="0" layout="mono">\
                <clip id="A" file="fa" start="1000" offset="1000" length="4000" gain="0" \(a)/>\
                <clip id="B" file="\(bFile)" start="5000" offset="\(bOffset)" length="4000" gain="\(bGain)" \(b)/></track>
                """
            return try Session(
                xml: Data(document(version: version, files: files, tracks: tracks).utf8), newest: newest)
        }

        let good = try? read("4", a: #"crossfadeOut="960""#, b: #"crossfadeIn="960""#)
        #expect(good?.clip("B")?.clip.crossfades == Crossfades(start: 960, end: 0), "a pair of 960 reads")
        let zero = try? read("4", a: #"crossfadeOut="0""#, b: #"crossfadeIn="0""#)
        #expect(zero?.clip("A")?.clip.crossfades == .zero, "a written 0 reads as no crossfade")
        let cases: [(String, String, String, SessionFileError)] = [
            (
                "3", #"crossfadeOut="960""#, #"crossfadeIn="960""#,
                .invalidValue(element: "clip", attribute: "crossfadeOut")
            ),
            (
                "4", #"crossfadeOut="961""#, #"crossfadeIn="961""#,
                .invalidValue(element: "clip", attribute: "crossfadeOut")
            ),
            (
                "4", #"crossfadeOut="960""#, #"crossfadeIn="-2""#,
                .invalidValue(element: "clip", attribute: "crossfadeIn")
            ),
            ("4", #"crossfadeIn="960""#, "", .invalidSession(.crossfadeWithoutJoin("A"))),
            ("4", #"crossfadeOut="960""#, "", .invalidSession(.crossfadeWithoutJoin("A"))),
            ("4", "", #"crossfadeIn="960""#, .invalidSession(.crossfadeWithoutJoin("B"))),
            ("4", #"crossfadeOut="960""#, #"crossfadeIn="962""#, .invalidSession(.crossfadeWithoutJoin("A"))),
            ("4", "", #"crossfadeOut="960""#, .invalidSession(.crossfadeWithoutJoin("B"))),
            (
                "4", #"crossfadeOut="960" fadeOut="10""#, #"crossfadeIn="960""#,
                .invalidSession(.fadeAtCrossfade("A"))
            ),
        ]
        for (version, a, b, error) in cases {
            #expect(throws: error, "version \(version), A \(a), B \(b)") { try read(version, a: a, b: b) }
        }
        #expect(throws: SessionFileError.invalidSession(.crossfadeOutsideFile("B", needed: 480)), "a short handle") {
            try read("4", a: #"crossfadeOut="960""#, b: #"crossfadeIn="960""#, bOffset: 479)
        }
        // Seamless crossfade C34: only version 9 holds a crossfade at a seamless join.
        let (out, into) = (#"crossfadeOut="960""#, #"crossfadeIn="960""#)
        for version in ["4", "8"] {
            #expect(
                throws: SessionFileError.invalidSession(.crossfadeAtSeamlessJoin("A")), "a seamless join in \(version)"
            ) { try read(version, a: out, b: into, bFile: "fa", bOffset: 5_000, bGain: "-6") }
        }
        for gain in ["-6", "0"] {
            let seamless = try? read("9", a: out, b: into, bFile: "fa", bOffset: 5_000, bGain: gain)
            #expect(
                seamless?.clip("B")?.clip.crossfades == Crossfades(start: 960, end: 0), "version 9, B at \(gain) dB")
        }
        #expect(throws: SessionFileError.unsupportedVersion(9), "a version 8 build refuses version 9") {
            try read("9", a: out, b: into, bFile: "fa", bOffset: 5_000, bGain: "-6", newest: 8)
        }
    }

    @Test(arguments: [
        ("<session", SessionFileError.malformedXML),
        (document(version: "\(sessionVersion + 1)"), .unsupportedVersion(sessionVersion + 1)),
        (
            document(tracks: #"<track id="t1" name="A" gain="0" layout="mono"><route app="us.zoom.xos"/></track>"#),
            .invalidValue(element: "route", attribute: "app")
        ),
        (
            document(
                version: "2",
                tracks:
                    #"<track id="t1" name="A" gain="0" layout="mono"><route device="d" channels="1" app="us.zoom.xos"/></track>"#
            ), .invalidValue(element: "route", attribute: "app")
        ),
        (
            document(
                version: "2",
                tracks:
                    #"<track id="t1" name="A" gain="0" layout="mono"><route app="us.zoom.xos" channels="1"/></track>"#
            ), .invalidValue(element: "route", attribute: "app")
        ),
        (
            document(version: "2", tracks: #"<track id="t1" name="A" gain="0" layout="mono"><route app=""/></track>"#),
            .invalidSession(.invalidRoute)
        ),
        (document(files: #"<file id="f1" path="a.wav" channels="3" length="10"/>"#), .invalidChannelCount(3)),
        (
            document(
                files: #"<file id="f1" path="a.wav" channels="2" length="10"/>"#,
                tracks:
                    #"<track id="t1" name="A" gain="0" layout="mono"><clip id="c1" file="f1" start="0" offset="0" length="10" gain="0"/></track>"#
            ), .invalidSession(.layoutMismatch("t1", .file("f1")))
        ),
        (
            document(
                tracks:
                    #"<track id="t1" name="A" gain="0" layout="mono"><clip id="c1" file="f9" start="0" offset="0" length="10" gain="0"/></track>"#
            ), .invalidSession(.unknownFile("f9"))
        ),
        (
            document(files: #"<file id="f1" path="a.wav" channels="1" length="10" capture="k9"/>"#),
            .invalidSession(.unknownCapture("k9"))
        ),
        (
            document(
                recording:
                    #"<recording take="1" playheadFrame="0" takeStartHostTimeNanos="5"><arm track="t9"/></recording>"#),
            .invalidSession(.unknownTrack("t9"))
        ),
        (
            document(recording: #"<recording take="1000000000" playheadFrame="0" takeStartHostTimeNanos="5"/>"#),
            .invalidSession(.takeOutOfRange(1_000_000_000))
        ),
        (
            document(
                tracks: #"<track id="t1" name="A" gain="0" layout="mono"><route device="d" channels="1 2"/></track>"#),
            .invalidSession(.layoutMismatch("t1", .route))
        ),
        (
            document(
                files: #"<file id="f1" path="a.wav" channels="1" length="10"/>"#,
                tracks:
                    #"<track id="t1" name="A" gain="0" layout="mono"><clip id="c1" file="f1" start="0" offset="5" length="10" gain="0"/></track>"#
            ), .invalidSession(.clipOutsideFile("c1"))
        ),
        (
            document(
                files: #"<file id="f1" path="a.wav" channels="1" length="10"/>"#,
                tracks:
                    #"<track id="t1" name="A" gain="0" layout="mono"><clip id="c1" file="f1" start="0" offset="0" length="10" gain="0"/><clip id="c2" file="f1" start="5" offset="0" length="10" gain="0"/></track>"#
            ), .invalidSession(.overlap("c2", "c1"))
        ),
        (
            document(
                files: #"<file id="f1" path="a.wav" channels="1" length="10"/>"#,
                tracks:
                    #"<track id="t1" name="A" gain="0" layout="mono"><clip id="c1" file="f1" start="1099511627777" offset="0" length="10" gain="0"/></track>"#
            ), .invalidSession(.frameOutOfRange)
        ),
        (
            document(
                files: #"<file id="f1" path="a.wav" channels="1" length="10"/>"#,
                tracks:
                    #"<track id="t1" name="A" gain="0" layout="mono"><clip id="c1" file="f1" start="0" offset="9223372036854775807" length="9223372036854775807" gain="0"/></track>"#
            ), .invalidSession(.clipOutsideFile("c1"))
        ),
        (
            document(
                files: #"<file id="f1" path="a.wav" channels="1" length="10"/>"#,
                tracks:
                    #"<track id="t1" name="A" gain="0" layout="mono"><clip id="c1" file="f1" start="0" offset="0" length="99999999999999999999" gain="0"/></track>"#
            ), .invalidValue(element: "clip", attribute: "length")
        ),
        (document(sampleRate: "0"), .invalidValue(element: "session", attribute: "sampleRate")),
        (
            document(
                captures:
                    #"<capture id="k1" deviceUID="d" deviceName="D" hostTimeNanos="1" sampleTime="0" nominalSampleRate="48000" measuredSampleRate="nan" latency="0"/>"#
            ), .invalidSession(.invalidCapture("k1"))
        ),
        (
            document(tracks: #"<track id="t1" name="A" gain="inf" layout="mono"/>"#),
            .invalidValue(element: "track", attribute: "gain")
        ),
        (
            document(tracks: #"<track id="t1" name="A" gain="0"/>"#),
            .missingAttribute(element: "track", attribute: "layout")
        ),
        (
            document(
                markers:
                    #"<marker id="m1" name="A" position="0" kind="marker"/><marker id="m1" name="B" position="9" kind="chapter"/>"#
            ), .invalidSession(.duplicateID("m1"))
        ),
        (#"<session xmlns="urn:other" version="1" sampleRate="48000"/>"#, .malformedXML),
    ])
    func refusesAnInvalidFile(xml: String, error: SessionFileError) throws {
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(xml.utf8).write(to: sessionXML)
        #expect(throws: error) { try Session(contentsOf: package) }
    }
}
