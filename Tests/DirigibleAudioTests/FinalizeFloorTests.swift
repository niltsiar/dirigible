import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The floor of an aligned finalize (decision 0004 **Timing**): no clip of a take starts before
/// the take playhead, 96,000 in the fixture. Each segment has latency 48.
struct FinalizeFloorTests {
    let package: TakePackage

    init() throws {
        package = try TakePackage(tracks: [("t1", .mono), ("t2", .mono)])
        try package.segment(arm: 2, samples: sine(seconds: 2, rate: 48_000, frequency: 500))
    }

    func segment(firstHostBeforeTakeStart seconds: UInt64, length: Double) throws {
        try package.segment(
            arm: 1, header: TakePackage.header(firstHost: takeStart - seconds * 1_000_000_000),
            samples: sine(seconds: length, rate: 48_000))
    }

    func clips(_ session: Session, _ track: TrackID) -> [Clip] { session.track(track)?.clips.map { $0 } ?? [] }

    @Test func framesBeforeTheFloorGoToTheOffset() throws {
        // File frame 0 is at 96,000 - 3 s - 48 = -48,048, so the playhead is file frame 144,048.
        try segment(firstHostBeforeTakeStart: 3, length: 5)

        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(
            clips(session, "t1") == [
                Clip(id: "take1-1-1", file: "take1-1-1", start: 96_000, offset: 144_048, length: 95_952)
            ])
        #expect(session.files["take1-1-1"]?.length == 240_000, "the file keeps the frames before the floor")
    }

    @Test func segmentAfterTheFloorIsUnchanged() throws {
        try package.segment(arm: 1, samples: sine(seconds: 2, rate: 48_000))

        let session = try finalizeTake(of: package.read(), in: package.url)

        // 96,000 + 480 (10 ms) - 48.
        #expect(
            clips(session, "t1") == [Clip(id: "take1-1-1", file: "take1-1-1", start: 96_432, offset: 0, length: 96_000)]
        )
    }

    @Test(arguments: [false, true])
    func segmentBeforeTheFloorIsAPoolFile(endsAtTheFloor: Bool) throws {
        // Ends at -48,048, or exactly at the floor: 96,000 + 48 frames after 3 s before the take start.
        if endsAtTheFloor {
            try package.segment(
                arm: 1, header: TakePackage.header(firstHost: takeStart - 1_000_000_000),
                samples: sine(seconds: 1, rate: 48_000) + [Float](repeating: 0, count: 48))
        } else {
            try segment(firstHostBeforeTakeStart: 5, length: 2)
        }

        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(clips(session, "t1").isEmpty)
        #expect(session.files["take1-1-1"]?.capture == "take1-1-1")
        #expect(session.captures["take1-1-1"] != nil)
        #expect(FileManager.default.fileExists(atPath: package.url.appending(path: "Clips/take1-1-1.wav").path))
        #expect(FileManager.default.fileExists(atPath: package.capture.appending(path: "take1-1-1.caf").path))
        #expect(unplacedSegments(segmentsWithAudio(in: package.url), session: session).isEmpty)
        #expect(clips(session, "t2").map(\.id) == ["take1-2-1"])
    }

    @Test(arguments: [false, true])
    @MainActor func alignedPlacementHasTheFloor(wholeBeforeTheFloor: Bool) async throws {
        try segment(firstHostBeforeTakeStart: 1, length: wholeBeforeTheFloor ? 0.5 : 2)
        var ended = try finalizeTake(of: package.read(), in: package.url)
        try ended.clear(.zero..<Frames.limit, on: ["t1"])
        try ended.removeFile("take1-1-1")
        try ended.write(to: package.url)
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([]), free: FreeBytes())
        let segment = try #require(SegmentName(stem: "take1-1-1"))
        try #require(studio.unplacedSegments == [segment])

        let placed = try await studio.place(segment)

        #expect(placed == (wholeBeforeTheFloor ? nil : "take1-1-1"))
        // File frame 0 is at 96,000 - 1 s - 48 = 47,952.
        #expect(
            clips(studio.session, "t1")
                == (wholeBeforeTheFloor
                    ? [] : [Clip(id: "take1-1-1", file: "take1-1-1", start: 96_000, offset: 48_048, length: 47_952)]))
        #expect(studio.session.files["take1-1-1"] != nil)
        #expect(studio.unplacedSegments == [])
    }
}
