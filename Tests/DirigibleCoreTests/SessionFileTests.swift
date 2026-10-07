import Foundation
import Testing

@testable import DirigibleCore

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
        #expect(try String(contentsOf: sessionXML, encoding: .utf8) == expected, "the version 1 document")
        #expect(FileManager.default.fileExists(atPath: package.appending(path: "Clips").path))
    }

    /// A2: a session with an app route saves version 2 and `<route app>`, and reads back.
    @Test func anAppRouteSavesVersion2() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Guest", layout: .mono)
        try session.addTrack("t2", name: "Host", layout: .mono)
        try session.setRoute(.app(bundleID: "us.zoom.xos"), track: "t1")
        try session.setRoute(.device(uid: "usb-1", channels: .mono(1)), track: "t2")
        #expect(session.fileVersion == 2, "one app route gives version 2")

        try session.write(to: package)

        let expected = """
            <?xml version="1.0" encoding="UTF-8"?>
            <session xmlns="https://github.com/niltsiar/dirigible/session" version="2" sampleRate="48000">
                <captures></captures>
                <files></files>
                <tracks>
                    <track id="t1" name="Guest" gain="0" layout="mono">
                        <route app="us.zoom.xos"></route>
                    </track>
                    <track id="t2" name="Host" gain="0" layout="mono">
                        <route device="usb-1" channels="1"></route>
                    </track>
                </tracks>
                <markers></markers>
            </session>
            """
        #expect(try String(contentsOf: sessionXML, encoding: .utf8) == expected, "the version 2 document")
        #expect(try Session(contentsOf: package) == session, "version 2 reads back")
    }

    /// A2 (0024 P6): with no app route the session saves version 1, also after the last app
    /// route goes.
    @Test func theLastAppRouteThatGoesSavesVersion1() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Guest", layout: .stereo)
        #expect(session.fileVersion == 1, "no app route gives version 1")
        try session.setRoute(.app(bundleID: "us.zoom.xos"), track: "t1")
        try session.write(to: package)
        #expect(try String(contentsOf: sessionXML, encoding: .utf8).contains(#"version="2""#))

        try session.setRoute(nil, track: "t1")
        try session.write(to: package)

        #expect(session.fileVersion == 1, "the last app route went")
        #expect(try String(contentsOf: sessionXML, encoding: .utf8).contains(#"version="1""#), "saved as version 1")
    }

    /// A2 (0024 P3): a version 1 reader refuses a version 2 file as newer.
    @Test func aVersion1ReaderRefusesVersion2() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Guest", layout: .mono)
        try session.setRoute(.app(bundleID: "us.zoom.xos"), track: "t1")
        let data = try session.checkedData()
        #expect(throws: SessionFileError.unsupportedVersion(2)) { try Session(xml: data, newest: 1) }
        #expect(try Session(xml: data) == session, "control: the current reader reads it")
    }

    /// Fades C1 (decision 0035): a fade saves version 3. A fade attribute is written only when it
    /// is not 0, and the file reads back equal.
    @Test func fadesWriteVersion3AndReadBack() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "a.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 10_000), on: "t1")
        try session.place(Clip(id: "c2", file: "f1", start: 20_000, offset: 0, length: 10_000), on: "t1")
        try session.place(Clip(id: "c3", file: "f1", start: 40_000, offset: 0, length: 10_000), on: "t1")
        try session.setFades(["c1": Fades(fadeIn: 480, fadeOut: 960)!, "c2": Fades(fadeIn: 0, fadeOut: 960)!])
        #expect(session.fileVersion == 3, "a fade gives version 3")

        try session.write(to: package)

        let xml = try String(contentsOf: sessionXML, encoding: .utf8)
        #expect(xml.contains(#"<session xmlns="https://github.com/niltsiar/dirigible/session" version="3""#))
        #expect(
            xml.contains(
                #"<clip id="c1" file="f1" start="0" offset="0" length="10000" gain="0" fadeIn="480" fadeOut="960">"#),
            "c1 has both fade attributes")
        #expect(
            xml.contains(#"<clip id="c2" file="f1" start="20000" offset="0" length="10000" gain="0" fadeOut="960">"#),
            "c2 has only fadeOut")
        #expect(
            xml.contains(#"<clip id="c3" file="f1" start="40000" offset="0" length="10000" gain="0">"#),
            "c3 has no fade attribute")
        #expect(try Session(contentsOf: package) == session, "version 3 reads back")
    }

    /// Fades C2 (0024 P6): with no fade, the version stays 1, or 2 with an app route, and no fade
    /// attribute is written.
    @Test func noFadeKeepsTheOldVersion() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "a.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 10_000), on: "t1")
        try session.setFades(["c1": .zero])
        try session.write(to: package)
        var xml = try String(contentsOf: sessionXML, encoding: .utf8)
        #expect(xml.contains(#"version="1""#), "every fade 0 gives version 1")
        #expect(!xml.contains("fadeIn") && !xml.contains("fadeOut"), "no fade attribute at 0")

        try session.setRoute(.app(bundleID: "us.zoom.xos"), track: "t1")
        #expect(session.fileVersion == 2, "an app route and no fade gives version 2")

        try session.setFades(["c1": Fades(fadeIn: 1, fadeOut: 0)!])
        try session.write(to: package)
        xml = try String(contentsOf: sessionXML, encoding: .utf8)
        #expect(xml.contains(#"version="3""#), "a fadeIn of 1 frame gives version 3")
    }

    /// Crossfades F1 (decision 0036): a crossfade writes version 4, crossfadeOut on A, and
    /// crossfadeIn on B, and reads back. A version 3 build refuses the file.
    @Test func crossfadesWriteVersion4AndReadBack() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "fa", path: "a.wav", layout: .mono, length: 10_000))
        try session.addFile(AudioFile(id: "fb", path: "b.wav", layout: .mono, length: 10_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "A", file: "fa", start: 1_000, offset: 1_000, length: 4_000), on: "t1")
        try session.place(Clip(id: "B", file: "fb", start: 5_000, offset: 1_000, length: 4_000), on: "t1")
        try session.setFades(["B": Fades(fadeIn: 0, fadeOut: 100)!])
        #expect(session.fileVersion == 3, "fades and no crossfade give version 3")
        try session.setCrossfades(["A": 960])
        #expect(session.fileVersion == 4, "a crossfade gives version 4")

        try session.write(to: package)
        let xml = try String(contentsOf: sessionXML, encoding: .utf8)
        #expect(xml.contains(#"<session xmlns="https://github.com/niltsiar/dirigible/session" version="4""#))
        #expect(
            xml.contains(
                #"<clip id="A" file="fa" start="1000" offset="1000" length="4000" gain="0" crossfadeOut="960">"#),
            "A has crossfadeOut")
        #expect(
            xml.contains(
                #"<clip id="B" file="fb" start="5000" offset="1000" length="4000" gain="0" fadeOut="100" crossfadeIn="960">"#
            ), "B has crossfadeIn")
        #expect(try Session(contentsOf: package) == session, "version 4 reads back")
        #expect(throws: SessionFileError.unsupportedVersion(4), "a version 3 build refuses version 4") {
            try Session(xml: Data(xml.utf8), newest: 3)
        }
    }

    /// A2: a version 2 file with no app route reads; the next save writes version 1.
    @Test func aVersion2FileWithNoAppRouteReads() throws {
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(document(version: "2", tracks: #"<track id="t1" name="A" gain="0" layout="mono"/>"#).utf8)
            .write(to: sessionXML)
        let session = try Session(contentsOf: package)
        #expect(session.tracks.map(\.id) == ["t1"])
        #expect(session.fileVersion == 1)
    }

    @Test func aFullSessionReadsBackEqual() throws {
        let session = try fullSession()
        try session.write(to: package)
        #expect(try Session(contentsOf: package) == session, "the full session reads back")
        #expect(
            try String(contentsOf: sessionXML, encoding: .utf8).contains(#"version="1""#), "device routes: version 1")
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

    @Test func savesThatOverlapLeaveOneWholeFile() async throws {
        let small = Session(sampleRate: 48_000)
        let large = try fullSession()
        let package = package
        for _ in 0..<20 {
            async let first: Void = Task.detached { try small.write(to: package) }.value
            async let second: Void = Task.detached { try large.write(to: package) }.value
            _ = try await (first, second)
            let read = try Session(contentsOf: package)
            #expect(read == small || read == large)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.path).sorted() == ["Clips", "session.xml"])
    }

    @Test func aFailedSaveKeepsTheOldFile() throws {
        try Session(sampleRate: 48_000).write(to: package)
        let old = try Data(contentsOf: sessionXML)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path) }

        #expect(throws: SessionFileError.writeFailed(step: "open", errno: EACCES)) {
            try fullSession().write(to: package)
        }
        #expect(try Data(contentsOf: sessionXML) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.path).sorted() == ["Clips", "session.xml"])
    }

    @Test func aFailedRenameRemovesTheTemporaryFile() throws {
        try FileManager.default.createDirectory(at: sessionXML, withIntermediateDirectories: true)
        #expect(throws: SessionFileError.writeFailed(step: "rename", errno: EISDIR)) {
            try fullSession().write(to: package)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.path).sorted() == ["Clips", "session.xml"])
    }

    /// A crash during a save leaves its temporary file (criterion 26).
    @Test func removeTemporaryFilesDeletesOnlyTheTemporaryFilesOfASave() throws {
        try fullSession().write(to: package)
        let leftover = ".session.xml.\(UUID().uuidString).tmp"
        for name in [leftover, "x.tmp", ".session.xml.tmp.bak", ".session.xml.not-a-uuid.tmp"] {
            FileManager.default.createFile(atPath: package.appending(path: name).path, contents: Data("x".utf8))
        }

        try fullSession().removeTemporaryFiles(in: package)

        #expect(
            try FileManager.default.contentsOfDirectory(atPath: package.path).sorted() == [
                ".session.xml.not-a-uuid.tmp", ".session.xml.tmp.bak", "Clips", "session.xml", "x.tmp",
            ])
        #expect(try Session(contentsOf: package) == fullSession())
    }

    /// Code gate 2: a crash during an import or a finalize leaves `Clips/.<stem>.wav.tmp`. A file
    /// that the pool names (`dirigible file add`) stays, in any case and with "./".
    @Test func removeTemporaryFilesDeletesTheTemporaryWAVsThatThePoolDoesNotName() throws {
        var session = try fullSession()
        try session.addFile(AudioFile(id: "f4", path: "./.Kept.wav.tmp", layout: .mono, length: 48_000))
        try session.write(to: package)
        let clips = package.appending(path: "Clips")
        for name in [".Voice.wav.tmp", ".kept.wav.tmp", "Voice.wav.tmp", ".Voice.wav", ".peaks.tmp"] {
            FileManager.default.createFile(atPath: clips.appending(path: name).path, contents: Data("x".utf8))
        }

        session.removeTemporaryFiles(in: package)

        #expect(
            try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted() == [
                ".Voice.wav", ".kept.wav.tmp", ".peaks.tmp", "Voice.wav.tmp",
            ])
    }

    @Test func aPrefixedFileInTheSessionNamespaceReads() throws {
        let xml = """
            <d:session xmlns:d="https://github.com/niltsiar/dirigible/session" version="1" sampleRate="48000">
            <d:tracks><d:track id="t1" name="Host" gain="0" layout="mono"/></d:tracks></d:session>
            """
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(xml.utf8).write(to: sessionXML)
        #expect(try Session(contentsOf: package).tracks.map(\.id) == ["t1"])
    }

    @Test func aMissingFileIsAReadFailure() {
        #expect(throws: SessionFileError.readFailed(errno: ENOENT)) { try Session(contentsOf: package) }
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
        try session.setRoute(Route.device(uid: "usb-1", channels: .mono(1)), track: "t1")
        try session.setRoute(Route.device(uid: "usb-2", channels: .stereo(3, 4)), track: "t2")
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
    tracks: String = "", markers: String = "", recording: String = ""
) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <session xmlns="https://github.com/niltsiar/dirigible/session" version="\(version)" sampleRate="\(sampleRate)">
    <captures>\(captures)</captures><files>\(files)</files><tracks>\(tracks)</tracks><markers>\(markers)</markers>\(recording)
    </session>
    """
}
