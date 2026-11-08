import Foundation
import Testing

@testable import DirigibleCore

/// Shuffle in Core (decision 0020, 0037) on fixture S. Track `t1` has a 0 ..< 48 000, b
/// 96 000 ..< 144 000, c 192 000 ..< 240 000, and d 288 000 ..< 336 000, each at the offset of its start.
/// Track `t2` has e 0 ..< 480 000 of file g. The markers are m1 at 200 000, m2 at 120 000 (inside b),
/// and m3 at 400 000.
struct ShuffleTests {
    var session: Session

    init() throws {
        session = try Self.fixture()
    }

    static func fixture() throws -> Session {
        var session = Session(sampleRate: 48_000)
        for file in ["f", "g"] as [FileID] {
            try session.addFile(AudioFile(id: file, path: "\(file).wav", layout: .mono, length: 480_000))
        }
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack("t2", name: "T2", layout: .mono)
        for (id, start) in [("a", 0), ("b", 96_000), ("c", 192_000), ("d", 288_000)] as [(ClipID, Int)] {
            try session.place(
                Clip(id: id, file: "f", start: Frames(start), offset: Frames(start), length: 48_000), on: "t1")
        }
        try session.place(Clip(id: "e", file: "g", start: 0, offset: 0, length: 480_000), on: "t2")
        for (id, position) in [("m1", 200_000), ("m2", 120_000), ("m3", 400_000)] as [(MarkerID, Int)] {
            try session.setMarker(Marker(id: id, name: id.rawValue, position: Frames(position), kind: .marker))
        }
        return session
    }

    func lane(_ track: TrackID) -> [Clip] {
        session.track(track).map { Array($0.clips) } ?? []
    }

    var markers: [Frames] { ["m1", "m2", "m3"].map { session.markers[MarkerID($0)]?.position ?? -1 } }

    func clip(_ id: ClipID, _ file: FileID, _ start: Int, offset: Int, length: Int = 48_000) -> Clip {
        Clip(id: id, file: file, start: Frames(start), offset: Frames(offset), length: Frames(length))
    }

    /// C43: the delete closes the old place first and the insert opens the drop in the timeline after the close.
    @Test mutating func aShuffleClosesTheOldPlaceAndOpensTheDrop() throws {
        var other = session
        var end = session

        try session.shuffle("b", to: "t1", start: 240_000)
        #expect(
            lane("t1") == [
                clip("a", "f", 0, offset: 0), clip("c", "f", 144_000, offset: 192_000),
                clip("b", "f", 240_000, offset: 96_000), clip("d", "f", 288_000, offset: 288_000),
            ])
        #expect(markers == [152_000, 96_000, 400_000], "m1 stays 8000 into c, m2 goes to the range start")
        #expect(lane("t2") == [clip("e", "g", 0, offset: 0, length: 480_000)])

        try other.shuffle("b", to: "t2", start: 100_000)
        #expect(
            other.track("t1").map { Array($0.clips) } == [
                clip("a", "f", 0, offset: 0), clip("c", "f", 144_000, offset: 192_000),
                clip("d", "f", 240_000, offset: 288_000),
            ])
        #expect(
            other.track("t2").map { Array($0.clips) } == [
                clip("e", "g", 0, offset: 0, length: 100_000), clip("b", "f", 100_000, offset: 96_000),
                clip("e@100000", "g", 148_000, offset: 100_000, length: 380_000),
            ])
        #expect(["m1", "m2", "m3"].map { other.markers[MarkerID($0)]?.position } == [200_000, 96_000, 400_000])

        try end.shuffle("b", to: "t2", start: 480_000)
        #expect(
            end.track("t2").map { Array($0.clips) } == [
                clip("e", "g", 0, offset: 0, length: 480_000), clip("b", "f", 480_000, offset: 96_000),
            ], "the end of e splits nothing")
        #expect(["m1", "m2", "m3"].map { end.markers[MarkerID($0)]?.position } == [152_000, 96_000, 352_000])
    }

    /// C43: no early return gives m2 at 144 000, because the delete puts it at 96 000 and the insert moves it.
    @Test mutating func aShuffleToItsOwnPlaceChangesNothing() throws {
        let before = session
        try session.shuffle("b", to: "t1", start: 96_000)
        #expect(session == before)
        #expect(markers == [200_000, 120_000, 400_000])
    }

    @Test mutating func aShuffleRefusesAnotherLayoutAndAFarStart() throws {
        try session.addTrack("s", name: "S", layout: .stereo)
        let before = session
        #expect(throws: SessionError.layoutMismatch("s", .file("f"))) { try session.shuffle("b", to: "s", start: 0) }
        #expect(session == before)
        #expect(throws: SessionError.frameOutOfRange) { try session.shuffle("b", to: "t1", start: Frames.limit + 1) }
        #expect(session == before)
        #expect(throws: SessionError.unknownClip("nobody")) { try session.shuffle("nobody", to: "t1", start: 0) }
        #expect(throws: SessionError.unknownTrack("nobody")) { try session.shuffle("b", to: "nobody", start: 0) }
        #expect(session == before)
    }

    /// C43 with decision 0073: the source and the target lane are named, so a follow target splits and a
    /// follow source closes; a third follow track `t3` stays as it is.
    @Test mutating func aFollowTrackThatIsNotTheTargetStays() throws {
        try session.addFile(AudioFile(id: "h", path: "h.wav", layout: .mono, length: 480_000))
        try session.addTrack("t3", name: "T3", layout: .mono)
        try session.place(Clip(id: "z", file: "h", start: 200_000, offset: 0, length: 60_000), on: "t3")
        try session.setFollowTrack(true, tracks: ["t1", "t2", "t3"])
        let third = lane("t3")

        try session.shuffle("b", to: "t2", start: 100_000)
        #expect(lane("t3") == third, "a follow track that is neither the source nor the target stays")
        #expect(lane("t2").map(\.id) == ["e", "b", "e@100000"], "the follow target splits")
        #expect(lane("t1").map(\.start) == [0, 144_000, 240_000], "the follow source closes")
    }
}
