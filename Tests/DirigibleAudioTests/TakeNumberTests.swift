import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A take number is never reused in a package (criterion 16).
struct TakeNumberTests {
    let folder: TemporaryFolder
    var package: URL { folder.url.appending(path: "Show.dirigible") }

    init() throws {
        folder = try TemporaryFolder()
        for name in ["Capture", "Clips"] {
            try FileManager.default.createDirectory(
                at: package.appending(path: name), withIntermediateDirectories: true)
        }
    }

    func touch(_ path: String) {
        FileManager.default.createFile(atPath: package.appending(path: path).path, contents: nil)
    }

    @Test func anEmptyPackageGetsTake1() {
        #expect(SegmentName.nextTake(in: package, session: Session(sampleRate: 48_000)) == 1)
        #expect(
            SegmentName.nextTake(in: folder.url.appending(path: "missing"), session: Session(sampleRate: 48_000)) == 1)
    }

    @Test func fileNamesInCaptureAndClipsCount() {
        touch("Capture/take2-1-1.caf")
        touch("Clips/take5-1-1.wav")
        #expect(SegmentName.nextTake(in: package, session: Session(sampleRate: 48_000)) == 6)
    }

    @Test func idsInTheSessionCount() throws {
        var session = Session(sampleRate: 48_000)
        try session.addCapture(
            Capture(
                id: "take3-1-1", deviceUID: "usb-1", deviceName: "Mic", hostTimeNanos: 0, sampleTime: 0,
                nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0))
        #expect(SegmentName.nextTake(in: package, session: session) == 4)

        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 100))
        try session.addTrack("t1", name: "A", layout: .mono)
        try session.place(Clip(id: "take9-1-1@48000", file: "f", start: 0, offset: 0, length: 100), on: "t1")
        #expect(SegmentName.nextTake(in: package, session: session) == 10)

        try session.setRecording(Recording(take: 7, playheadFrame: 0, takeStartHostTimeNanos: 0, armedTracks: []))
        #expect(SegmentName.nextTake(in: package, session: session) == 10)
        try session.setRecording(Recording(take: 12, playheadFrame: 0, takeStartHostTimeNanos: 0, armedTracks: []))
        #expect(SegmentName.nextTake(in: package, session: session) == 13)
    }

    /// Decision 0024 P10: a take with no audio leaves only its anchor.
    @Test func anAnchorAloneKeepsItsTakeNumber() {
        touch("Capture/take3.anchor")
        #expect(SegmentName.nextTake(in: package, session: Session(sampleRate: 48_000)) == 4)
    }

    /// Decision 0071 (C12): after the removal of the CAF of take 3 and a revert to a session with
    /// no take, the files that the removal keeps give take 4.
    @Test func aRemovedCAFKeepsItsTakeNumber() async throws {
        let take = try TakePackage(take: 3)
        try take.segment(take: 3, samples: sine(seconds: 2, rate: 48_000))
        let url = take.url
        try await offMainActor {
            let outcome = completeTake(of: try Session(contentsOf: url), lock: try PackageLock(url), level: false) {
                session throws(SessionFileError) in try session.write(to: url)
            }
            let removable = removableCaptures(of: outcome.session, in: url)
            #expect(removable.map(\.name.stem) == ["take3-1-1"])
            for candidate in removable {
                #expect(try removeRawCapture(candidate.name, of: outcome.session, in: url, read: candidate.read))
            }
        }
        try #require(!FileManager.default.fileExists(atPath: take.capture.appending(path: "take3-1-1.caf").path))
        #expect(SegmentName.nextTake(in: url, session: Session(sampleRate: 48_000)) == 4)
    }

    /// Decision 0024 P10: a file of a newer build keeps its take number. A name counts when
    /// `take`, 1 to 9 digits with no leading zero, and then a byte that is not a digit start it.
    @Test(arguments: [
        ("Capture/take7-1-1.future", 8), ("Clips/take12x", 13), ("Capture/takes3", 1), ("Capture/take05.anchor", 1),
    ])
    func anUnknownTakeFileKeepsItsNumber(name: String, next: Int) {
        touch(name)
        #expect(SegmentName.nextTake(in: package, session: Session(sampleRate: 48_000)) == next)
    }

    @Test func otherNamesAndIDsDoNotCount() throws {
        for name in ["take-1-1.caf", "take01-1-1.caf", "take1234567890-1-1.caf", "notes.txt"] {
            touch("Capture/\(name)")
        }
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "take01-1-1", path: "a.wav", layout: .mono, length: 100))
        try session.addFile(AudioFile(id: "take1234567890-1-1", path: "b.wav", layout: .mono, length: 100))
        #expect(SegmentName.nextTake(in: package, session: session) == 1)
    }
}
