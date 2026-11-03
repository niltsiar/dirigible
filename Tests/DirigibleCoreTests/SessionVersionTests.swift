import Foundation
import Testing

@testable import DirigibleCore

/// The `preRoll` mark of a `<recording>` (decision 0024 P6 and P7): version 15 while a pre-roll
/// take is in the session, and the version of before after it.
struct SessionVersionTests {
    let files = SessionFileTests()

    func withTake(_ session: Session, preRoll: Bool) throws -> Session {
        var session = session
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRecording(
            Recording(
                take: 2, playheadFrame: 96_000, takeStartHostTimeNanos: 13_018_583_333, armedTracks: ["t1"],
                isPreRoll: preRoll))
        return session
    }

    func text(_ session: Session) throws -> String { String(decoding: try session.checkedData(), as: UTF8.self) }

    /// P31: a pre-roll `<recording>` gives 15, also when a repair effect in a file origin gives 14.
    @Test func preRollRecordingRaisesTheVersion() throws {
        let repaired = try files.renderedBeforeSource(try files.allRepairs())
        #expect(repaired.fileVersion == 14)

        for base in [Session(sampleRate: 48_000), repaired] {
            let session = try withTake(base, preRoll: true)
            let text = try text(session)

            #expect(session.fileVersion == 15)
            #expect(text.contains(#"version="15""#) && text.contains(#"preRoll="true""#), "\(text)")
        }
    }

    /// P31: a plain take and the session after the pre-roll take write the version of before, and
    /// no `preRoll` attribute.
    @Test func versionDropsAfterTheTake() throws {
        let repaired = try files.renderedBeforeSource(try files.allRepairs())
        for (base, before) in [(Session(sampleRate: 48_000), 1), (repaired, 14)] {
            var session = try withTake(base, preRoll: true)
            #expect(session.fileVersion == 15)

            try session.setRecording(nil)
            let plain = try withTake(base, preRoll: false)

            for after in [session, plain] {
                let text = try text(after)
                #expect(after.fileVersion == before)
                #expect(text.contains(#"version="\#(before)""#) && !text.contains("preRoll"), "\(text)")
            }
        }
    }

    /// P31: a file of version 14 with `preRoll="true"` is refused, and the same file at 15 reads.
    @Test func preRollBelowItsVersionIsRefused() throws {
        let session = try withTake(Session(sampleRate: 48_000), preRoll: true)
        let text = try text(session)
        let older = text.replacingOccurrences(of: #"version="15""#, with: #"version="14""#)
        #expect(older != text)

        #expect(throws: SessionFileError.invalidValue(element: "recording", attribute: "preRoll")) {
            try Session(xml: Data(older.utf8))
        }
        #expect(try Session(xml: Data(text.utf8)) == session)
    }

    /// The reader of this build refuses a `preRoll` value other than `true`.
    @Test(arguments: ["false", "yes", "1", ""])
    func badPreRollValueIsRefused(value: String) throws {
        let text = try text(withTake(Session(sampleRate: 48_000), preRoll: true))
        let bad = text.replacingOccurrences(of: #"preRoll="true""#, with: #"preRoll="\#(value)""#)
        #expect(bad != text)

        #expect(throws: SessionFileError.invalidValue(element: "recording", attribute: "preRoll")) {
            try Session(xml: Data(bad.utf8))
        }
    }

    /// The pre-roll session goes through `write(to:)` and its `checkedData()` read back, and a
    /// read of the package gives the equal session.
    @Test func preRollRecordingRoundTrips() throws {
        let session = try withTake(Session(sampleRate: 48_000), preRoll: true)

        try session.write(to: files.package)

        let read = try Session(contentsOf: files.package)
        #expect(read == session && read.recording?.isPreRoll == true)
    }
}
