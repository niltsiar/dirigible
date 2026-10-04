import DirigibleAudio
import DirigibleCore
import Foundation
import Testing

/// `rippleBlocked` (decision 0037, criterion C20): a ripple must not move the timeline under a
/// pending take or a split take. Take 1 has segments `take1-1-1` and `take1-2-1`. No file I/O.
struct RipplePredicateTests {
    let takeOne = ["take1-1-1", "take1-2-1"].compactMap { SegmentName(stem: $0) }
    var session: Session

    init() throws {
        session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
    }

    /// Adds the capture and the pool file of the segment `stem`, as a finalize does.
    mutating func place(_ stem: String) throws {
        try session.addCapture(
            Capture(
                id: CaptureID(stem), deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: 0, sampleTime: 0,
                nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0))
        try session.addFile(
            AudioFile(id: FileID(stem), path: "\(stem).wav", layout: .mono, length: 96_000, capture: CaptureID(stem)))
    }

    @Test func noSegmentAllowsARipple() {
        #expect(takeOne.count == 2)
        #expect(!rippleBlocked(segments: [], session: session), "RIPPLE-P1 no segment and no recording blocks")
    }

    @Test func aWhollyUnplacedTakeAllowsARipple() {
        #expect(!rippleBlocked(segments: takeOne, session: session), "RIPPLE-P2 a wholly unplaced take blocks")
    }

    @Test mutating func aWhollyPlacedTakeAllowsARipple() throws {
        try place("take1-1-1")
        try place("take1-2-1")
        #expect(!rippleBlocked(segments: takeOne, session: session), "RIPPLE-P3 a wholly placed take blocks")
    }

    @Test mutating func aSplitTakeBlocksARipple() throws {
        try place("take1-2-1")
        #expect(rippleBlocked(segments: takeOne, session: session), "RIPPLE-P4 a split take does not block")
        let otherTake = ["take2-1-1"].compactMap { SegmentName(stem: $0) }
        #expect(
            !rippleBlocked(segments: otherTake, session: session),
            "RIPPLE-P5 an unplaced take beside another placed take blocks")
    }

    @Test mutating func aRecordingBlocksARipple() throws {
        try session.setRecording(Recording(take: 2, playheadFrame: 0, takeStartHostTimeNanos: 0, armedTracks: ["t1"]))
        #expect(rippleBlocked(segments: [], session: session), "RIPPLE-P6 a recording does not block")
    }
}
