import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The floor of a plain take (decision 0004 **Timing**): a take at playhead 96,000 places no clip
/// before it, so a segment before it leaves no unplaced segment, and an old clip that ends just
/// before it keeps its tail.
struct StudioFloorTests {
    @Test @MainActor func plainTakeBeforeTheFloorLeavesNoUnplacedSegment() async throws {
        let package = try TakePackage(tracks: [("t1", .mono)])
        // A segment that ends 1 s before the playhead: 96,000 - 2 s - 48 to 48,000 - 48.
        try package.segment(
            arm: 1, header: TakePackage.header(firstHost: takeStart - 2_000_000_000),
            samples: sine(seconds: 1, rate: 48_000))

        // The open finalizes the pending take (decision 0004).
        let studio = try await Studio.open(package.url)

        #expect(studio.session.recording == nil)
        #expect(studio.session.track("t1")?.clips.isEmpty == true)
        #expect(studio.session.files["take1-1-1"]?.capture == "take1-1-1")
        #expect(studio.unplacedSegments.isEmpty)
        #expect(studio.canRipple)
    }

    @Test func plainTakeKeepsTheTailBeforeThePlayhead() throws {
        let package = try TakePackage(tracks: [("t1", .mono)])
        // An old clip that ends 24 frames before the playhead, inside the input latency of 48.
        let old = Clip(id: "old", file: "old", start: 48_000, offset: 0, length: 47_976)
        var session = try package.read()
        try session.addFile(AudioFile(id: "old", path: "old.wav", layout: .mono, length: 47_976))
        try session.place(old, on: "t1")
        try session.write(to: package.url)
        // The first frame at the take start: file frame 0 is at 96,000 - 48.
        try package.segment(
            arm: 1, header: TakePackage.header(firstHost: takeStart), samples: sine(seconds: 1, rate: 48_000))

        let ended = try finalizeTake(of: package.read(), in: package.url)

        #expect(
            ended.track("t1")?.clips.map { $0 } == [
                old, Clip(id: "take1-1-1", file: "take1-1-1", start: 96_000, offset: 48, length: 47_952),
            ])
    }
}
