import Foundation
import Testing

@testable import DirigibleCore

/// The `preRoll` mark of a `<recording>` (decision 0024 P6 and P7): `preRollSessionVersion` while a
/// pre-roll take is in the session, and the version of before after it.
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

    /// P31: a pre-roll `<recording>` gives `preRollSessionVersion`, also when a repair effect in a
    /// file origin gives 14.
    @Test func preRollRecordingRaisesTheVersion() throws {
        let repaired = try files.renderedBeforeSource(try files.allRepairs())
        #expect(repaired.fileVersion == 14)

        for base in [Session(sampleRate: 48_000), repaired] {
            let session = try withTake(base, preRoll: true)
            let text = try text(session)

            #expect(session.fileVersion == preRollSessionVersion)
            #expect(
                text.contains(#"version="\#(preRollSessionVersion)""#) && text.contains(#"preRoll="true""#), "\(text)")
        }
    }

    /// P31: a plain take and the session after the pre-roll take write the version of before, and
    /// no `preRoll` attribute.
    @Test func versionDropsAfterTheTake() throws {
        let repaired = try files.renderedBeforeSource(try files.allRepairs())
        for (base, before) in [(Session(sampleRate: 48_000), 1), (repaired, 14)] {
            var session = try withTake(base, preRoll: true)
            #expect(session.fileVersion == preRollSessionVersion)

            try session.setRecording(nil)
            let plain = try withTake(base, preRoll: false)

            for after in [session, plain] {
                let text = try text(after)
                #expect(after.fileVersion == before)
                #expect(text.contains(#"version="\#(before)""#) && !text.contains("preRoll"), "\(text)")
            }
        }
    }

    /// P31: a file one version below `preRollSessionVersion` with `preRoll="true"` is refused, and the
    /// same file at that version reads.
    @Test func preRollBelowItsVersionIsRefused() throws {
        let session = try withTake(Session(sampleRate: 48_000), preRoll: true)
        let text = try text(session)
        let older = text.replacingOccurrences(
            of: #"version="\#(preRollSessionVersion)""#, with: #"version="\#(preRollSessionVersion - 1)""#)
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

    /// Each `package let <name>SessionVersion = <n>` of `SessionWriter.swift` has its own number, and
    /// `sessionVersion` names the largest, so two runs that take one number fail here.
    @Test func eachSessionVersionIsDistinctAndTheNewestIsTheLargest() throws {
        let writer = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/DirigibleCore/SessionWriter.swift")
        let text = try String(contentsOf: writer, encoding: .utf8)
        #expect(versionProblems(in: text).isEmpty, "\(versionProblems(in: text))")
        #expect(versionConstants(in: text).count >= 2)

        let shared = text + "\npackage let otherSessionVersion = \(sessionVersion)\n"
        #expect(!versionProblems(in: shared).isEmpty, "a second constant with the newest number")
        let oldest = try #require(versionConstants(in: text).min { $0.value < $1.value }?.key)
        let stale = text.replacing(#/package let sessionVersion = \w+/#, with: "package let sessionVersion = \(oldest)")
        #expect(!versionProblems(in: stale).isEmpty, "sessionVersion names a lower constant")
    }

    func versionConstants(in text: String) -> [String: Int] {
        var constants: [String: Int] = [:]
        for match in text.matches(of: #/package let (\w+SessionVersion) = (\d+)/#) {
            constants[String(match.1), default: 0] = Int(match.2) ?? -1
        }
        return constants
    }

    func versionProblems(in text: String) -> [String] {
        let constants = versionConstants(in: text)
        var problems: [String] = []
        let numbers = constants.values.sorted()
        if Set(numbers).count != numbers.count { problems.append("two constants share a number: \(constants)") }
        let newest = text.firstMatch(of: #/package let sessionVersion = (\w+)/#).map { String($0.1) }
        if newest.flatMap({ constants[$0] }) != numbers.last {
            problems.append("sessionVersion is \(newest ?? "missing"), not the largest of \(constants)")
        }
        return problems
    }

    /// From 12 on, `fileVersion` is the largest version of the present features. A
    /// repair origin (14), a pre-roll take, a follow track, a ride point, and a voice match, alone
    /// and together, write the larger constant and read back equal.
    @Test func fileVersionIsTheMaxOfThePresentFeatures() throws {
        let repaired = try files.renderedBeforeSource(try files.allRepairs())
        var ridden = repaired
        try ridden.addTrack("r", name: "Ride", layout: .mono)
        try ridden.place(Clip(id: "R", file: "z", start: 0, offset: 0, length: 1_000), on: "r")
        try ridden.setRides(["R": envelope([(500, -1.5)])])
        var followed = repaired
        try followed.addTrack("f", name: "Bed", layout: .mono)
        try followed.setFollowTrack(true, tracks: ["f"])
        var riddenFollowed = ridden
        try riddenFollowed.setFollowTrack(true, tracks: ["r"])
        var matched = riddenFollowed
        try matched.setMatch(["r": VoiceMatchTests.match(VoiceMatchTests.flat)])
        let cases: [(Session, Int)] = [
            (repaired, 14), (ridden, rideSessionVersion), (followed, followSessionVersion),
            (riddenFollowed, rideSessionVersion), (matched, matchSessionVersion),
            (try withTake(repaired, preRoll: true), preRollSessionVersion),
            (try withTake(followed, preRoll: true), followSessionVersion),
            (try withTake(ridden, preRoll: true), rideSessionVersion),
        ]
        for (session, version) in cases {
            #expect(session.fileVersion == version)
            #expect(try text(session).contains(#"version="\#(version)""#))
            #expect(try Session(xml: try session.checkedData()) == session)
        }
        #expect(rideSessionVersion > followSessionVersion && matchSessionVersion > rideSessionVersion)
        #expect(sessionVersion == matchSessionVersion)
    }
}
