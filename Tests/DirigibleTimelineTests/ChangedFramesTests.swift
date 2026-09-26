import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// The dirty rect of a drag event (decision 0020): the frames of the changed clips, on the small
/// fixture (A 48,000 ..< 96,000 and B 144,000 ..< 192,000 on t1, C 48,000 ..< 96,000 on t2).
struct ChangedFramesTests {
    @Test func aMoveChangesTheFramesOfItsOldAndNewPlaceAndOfTheClipsItCuts() throws {
        let session = try Fixture.session()
        var moved = session
        try moved.move("A", to: "t1", start: 72_000)
        var over = session
        try over.move("A", to: "t1", start: 150_000)

        #expect(changedFrames(from: session, to: moved) == 48_000..<120_000)
        #expect(changedFrames(from: moved, to: over) == 72_000..<198_000, "B is cut to 144,000 ..< 150,000")
        #expect(changedFrames(from: session, to: session) == .zero ..< .zero)
        var later = session
        try later.move("B", to: "t1", start: 200_000)
        #expect(changedFrames(from: session, to: later) == 144_000..<248_000, "A before B does not change")
    }

    @Test func aMoveToAnotherLaneChangesBothLanes() throws {
        let session = try Fixture.session()
        var moved = session
        try moved.move("A", to: "t2", start: 96_000)

        #expect(changedFrames(from: session, to: moved) == 48_000..<144_000)
    }

    @Test func aChangeOutsideTheClipsRedrawsAll() throws {
        let session = try Fixture.session()
        var gain = session
        try gain.setGain(Gain(dB: -6)!, track: "t2")
        var marker = session
        try marker.setMarker(Marker(id: "m1", name: "M", position: 1000, kind: .marker))
        var track = session
        try track.addTrack("t4", name: "T4", layout: .mono)

        #expect(changedFrames(from: session, to: gain) == nil)
        #expect(changedFrames(from: session, to: marker) == nil)
        #expect(changedFrames(from: session, to: track) == nil)
    }
}
