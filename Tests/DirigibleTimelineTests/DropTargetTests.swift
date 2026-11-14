import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Run 13c criterion C7: the import target of a drop point (`LaneGeometry.dropTarget`). The
/// frame is the frame under the pointer; one file on a lane goes to its track; a drop of 2 or more
/// files, or a drop in the New Track zone at the bottom of the lanes in view, goes to new tracks.
struct DropTargetTests {
    /// A session with `count` mono tracks t0 ..< t`count`, and no clip.
    func session(tracks count: Int) throws -> Session {
        var session = Session(sampleRate: 48_000)
        for index in 0..<count { try session.addTrack(TrackID("t\(index)"), name: "T\(index)", layout: .mono) }
        return session
    }

    func geometry(framesPerPoint: Double = 480, laneHeight: Double = 100) -> LaneGeometry {
        LaneGeometry(scale: TimelineScale(framesPerPoint: framesPerPoint), laneHeight: laneHeight, range: .standard)!
    }

    @Test func xAtOrBeforeZeroGivesFrameZero() throws {
        let session = try session(tracks: 3)
        let geometry = geometry()

        #expect(geometry.dropTarget(x: -5, y: 50, files: 1, bottom: 500, in: session).start == 0)
        #expect(geometry.dropTarget(x: 0, y: 50, files: 1, bottom: 500, in: session).start == 0)
        #expect(geometry.dropTarget(x: 1, y: 50, files: 1, bottom: 500, in: session).start == 480)
    }

    @Test func aFractionalScaleRoundsTheFrameDown() throws {
        let geometry = geometry(framesPerPoint: 480.5)

        #expect(geometry.dropTarget(x: 3, y: 50, files: 1, bottom: 500, in: try session(tracks: 3)).start == 1_441)
    }

    @Test func oneFileOnALaneGoesToItsTrack() throws {
        let session = try session(tracks: 3)
        let geometry = geometry()

        #expect(
            geometry.dropTarget(x: 10, y: 0, files: 1, bottom: 500, in: session)
                == ImportTarget(track: "t0", start: 4_800))
        #expect(geometry.dropTarget(x: 10, y: 150, files: 1, bottom: 500, in: session).track == "t1")
        #expect(geometry.dropTarget(x: 10, y: 299, files: 1, bottom: 500, in: session).track == "t2")
    }

    @Test func twoFilesGoToNewTracksAtAnyY() throws {
        let session = try session(tracks: 3)
        let geometry = geometry()

        for y in [0.0, 150, 299, 400] {
            #expect(
                geometry.dropTarget(x: 10, y: y, files: 2, bottom: 500, in: session)
                    == ImportTarget(track: nil, start: 4_800), "y \(y)")
        }
    }

    /// C7 e: the zone is at most half a lane high, so each lane fully in view keeps at least half
    /// its height as a target. With lanes that fill the view, the zone is the last 32 pt.
    @Test func theNewTrackZoneIsThirtyTwoPointsOverFullLanes() throws {
        let geometry = geometry()
        let full = try session(tracks: 6)

        #expect(geometry.dropTarget(x: 10, y: 468, files: 1, bottom: 500, in: full).track == nil, "the zone top")
        #expect(geometry.dropTarget(x: 10, y: 467, files: 1, bottom: 500, in: full).track == "t4")
    }

    /// C7 e: with room below the lanes, the zone starts at the end of the last lane.
    @Test func theNewTrackZoneStartsBelowTheLastLane() throws {
        let geometry = geometry()
        let short = try session(tracks: 3)

        #expect(geometry.dropTarget(x: 10, y: 300, files: 1, bottom: 500, in: short).track == nil)
        #expect(geometry.dropTarget(x: 10, y: 299, files: 1, bottom: 500, in: short).track == "t2")
    }

    /// C7 f: at the 40 pt minimum lane height, the zone is half a lane (20 pt), not 32 pt.
    @Test func theNewTrackZoneIsHalfASmallLane() throws {
        let geometry = geometry(laneHeight: 40)
        let session = try session(tracks: 15)

        #expect(geometry.dropTarget(x: 10, y: 480, files: 1, bottom: 500, in: session).track == nil)
        #expect(geometry.dropTarget(x: 10, y: 479, files: 1, bottom: 500, in: session).track == "t11")
    }
}
