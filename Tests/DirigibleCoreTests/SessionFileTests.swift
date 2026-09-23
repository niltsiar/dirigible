import DirigibleCore
import Foundation
import Testing

struct SessionFileTests {
    let package: URL

    init() {
        package = FileManager.default.temporaryDirectory
            .appending(path: "SessionFileTests-\(UUID().uuidString)/Episode.dirigible")
    }

    var sessionXML: URL { package.appending(path: "session.xml") }

    @Test func writesTheExpectedDocument() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "a.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "Host & Co", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 480_000), on: "t1")
        try session.setMarker(Marker(id: "m1", name: "Intro", position: 48_000, kind: .chapter))

        try session.write(to: package)

        let expected = """
            <?xml version="1.0" encoding="UTF-8"?>
            <session xmlns="https://github.com/niltsiar/dirigible/session" version="1" sampleRate="48000">
                <captures></captures>
                <files>
                    <file id="f1" path="a.wav" channels="1" length="480000"></file>
                </files>
                <tracks>
                    <track id="t1" name="Host &amp; Co" gain="0" layout="mono">
                        <clip id="c1" file="f1" start="0" offset="0" length="480000" gain="0"></clip>
                    </track>
                </tracks>
                <markers>
                    <marker id="m1" name="Intro" position="48000" kind="chapter"></marker>
                </markers>
            </session>
            """
        #expect(try String(contentsOf: sessionXML, encoding: .utf8) == expected)
        #expect(FileManager.default.fileExists(atPath: package.appending(path: "Clips").path))
    }

    @Test func aFullSessionReadsBackEqual() throws {
        let session = try fullSession()
        try session.write(to: package)
        #expect(try Session(contentsOf: package) == session)
    }

    @Test func framesAtTheLimitReadBack() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "a.wav", layout: .mono, length: Frames.limit))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: Frames.limit, offset: 0, length: Frames.limit), on: "t1")
        try session.write(to: package)
        #expect(try Session(contentsOf: package) == session)
    }

    @Test func aSnapshotWritesOffTheMainActor() async throws {
        let session = try fullSession()
        let package = package
        try await Task.detached { try session.write(to: package) }.value
        #expect(try Session(contentsOf: package) == session)
    }

    @Test func aFailedSaveKeepsTheOldFile() throws {
        try Session(sampleRate: 48_000).write(to: package)
        let old = try Data(contentsOf: sessionXML)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path) }

        #expect(throws: SessionFileError.self) { try fullSession().write(to: package) }
        #expect(try Data(contentsOf: sessionXML) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.path).sorted() == ["Clips", "session.xml"])
    }

    @Test func aFailedRenameRemovesTheTemporaryFile() throws {
        try FileManager.default.createDirectory(at: sessionXML, withIntermediateDirectories: true)
        #expect(throws: SessionFileError.self) { try fullSession().write(to: package) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.path).sorted() == ["Clips", "session.xml"])
    }

    @Test func aMissingFileIsAReadFailure() {
        #expect {
            try Session(contentsOf: package)
        } throws: { error in
            if case SessionFileError.readFailed = error { true } else { false }
        }
    }

    // MARK: Refused files

    @Test(arguments: [
        ("<session", SessionFileError.malformedXML),
        (document(version: "2"), .unsupportedVersion(2)),
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
    ])
    func refusesAnInvalidFile(xml: String, error: SessionFileError) throws {
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(xml.utf8).write(to: sessionXML)
        #expect(throws: error) { try Session(contentsOf: package) }
    }

    // MARK: Fixtures

    func fullSession() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addCapture(
            Capture(
                id: "k1", deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: 123_456_789_012,
                sampleTime: 5_120.5, nominalSampleRate: 48_000, measuredSampleRate: 48_000.37, latency: 64))
        try session.addCapture(
            Capture(
                id: "k2", deviceUID: "usb-2", deviceName: "Interface \"B\"", hostTimeNanos: 123_456_790_000,
                sampleTime: 0, nominalSampleRate: 44_100, measuredSampleRate: 44_099.8, latency: 128,
                resampledFromRate: 44_100, driftCorrected: false))
        try session.addFile(AudioFile(id: "f1", path: "t1-1-1.wav", layout: .mono, length: 480_000, capture: "k1"))
        try session.addFile(AudioFile(id: "f2", path: "t2-1-1.wav", layout: .stereo, length: 441_000, capture: "k2"))
        try session.addFile(AudioFile(id: "f3", path: "imported/intro.wav", layout: .stereo, length: 96_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .stereo)
        try session.setRoute(Route(deviceUID: "usb-1", channels: .mono(1)), track: "t1")
        try session.setRoute(Route(deviceUID: "usb-2", channels: .stereo(3, 4)), track: "t2")
        try session.setGain(Gain(dB: -2.5)!, track: "t2")
        try session.place(Clip(id: "c1", file: "f1", start: 1_000, offset: 0, length: 480_000), on: "t1")
        try session.place(Clip(id: "c3", file: "f3", start: 0, offset: 0, length: 96_000), on: "t2")
        try session.place(
            Clip(id: "c2", file: "f2", start: 96_000, offset: 500, length: 400_000, gain: Gain(dB: 3.25)!), on: "t2")
        try session.setMarker(Marker(id: "m1", name: "Intro", position: 0, kind: .marker))
        try session.setMarker(
            Marker(id: "m2", name: "Kapitel 1 – Gäste \u{7F} <&> \"' 🎙️", position: 96_000, kind: .chapter))
        try session.setRecording(
            Recording(take: 2, playheadFrame: 600_000, takeStartHostTimeNanos: 999_000, armedTracks: ["t2", "t1"]))
        return session
    }
}

/// A version 1 document with the given parts.
func document(
    version: String = "1", sampleRate: String = "48000", captures: String = "", files: String = "",
    tracks: String = "", recording: String = ""
) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <session xmlns="https://github.com/niltsiar/dirigible/session" version="\(version)" sampleRate="\(sampleRate)">
    <captures>\(captures)</captures><files>\(files)</files><tracks>\(tracks)</tracks><markers/>\(recording)
    </session>
    """
}
