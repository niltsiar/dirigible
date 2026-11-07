import Foundation
import Testing

@testable import DirigibleCore

/// The ripple trim (decision 0037, criterion C11) on `editFixture()`. Track "a" has clip "A" at
/// 48 000..<96 000 with offset 100 000 and clip "B" at 120 000..<144 000. Track "b" has clip "W"
/// at 0..<200 000. File "f" has 480 000 frames. Each case moves an edge by d = 4 800.
struct RippleTrimTests {
    var session: Session

    init() throws {
        session = try editFixture()
        try session.place(Clip(id: "A", file: "f", start: 48_000, offset: 100_000, length: 48_000), on: "a")
        try session.place(Clip(id: "B", file: "f", start: 120_000, offset: 0, length: 24_000), on: "a")
        try session.place(Clip(id: "W", file: "f", start: 0, offset: 0, length: 200_000), on: "b")
    }

    func lane(_ track: TrackID) -> [Clip] {
        session.track(track).map { Array($0.clips) } ?? []
    }

    /// All crossfades of the lanes, by clip ID; a clip with none is left out.
    var allCrossfades: [ClipID: Crossfades] {
        Dictionary(
            uniqueKeysWithValues: session.tracks.flatMap(\.clips).filter { $0.crossfades != .zero }.map {
                ($0.id, $0.crossfades)
            })
    }

    /// C11 end shorter. Control: the plain `trim` moves no other clip.
    @Test mutating func anEndTrimShorterRipplesEveryScopeTrack() throws {
        try session.setMarker(Marker(id: "m", name: "m", position: 130_000, kind: .marker))
        try session.rippleTrim("A", edge: .end, by: -4_800, on: ["a", "b"], naming: [])
        #expect(
            lane("a") == [
                Clip(id: "A", file: "f", start: 48_000, offset: 100_000, length: 43_200),
                Clip(id: "B", file: "f", start: 115_200, offset: 0, length: 24_000),
            ], "A ends d earlier, and B moves left by d")
        #expect(
            lane("b") == [
                Clip(id: "W", file: "f", start: 0, offset: 0, length: 91_200),
                Clip(id: "W@96000", file: "f", start: 91_200, offset: 96_000, length: 104_000),
            ], "b loses the span before the old end and closes the gap")
        #expect(session.markers["m"]?.position == 125_200, "a marker after the old end moves left")
    }

    /// C11 end longer.
    @Test mutating func anEndTrimLongerInsertsSilenceOnTheOtherTracks() throws {
        try session.rippleTrim("A", edge: .end, by: 4_800, on: ["a", "b"], naming: [])
        #expect(
            lane("a") == [
                Clip(id: "A", file: "f", start: 48_000, offset: 100_000, length: 52_800),
                Clip(id: "B", file: "f", start: 124_800, offset: 0, length: 24_000),
            ])
        #expect(
            lane("b") == [
                Clip(id: "W", file: "f", start: 0, offset: 0, length: 96_000),
                Clip(id: "W@96000", file: "f", start: 100_800, offset: 96_000, length: 104_000),
            ], "b gets d of silence at the old end")
    }

    /// C11 start shorter: the clip start stays, and its offset grows by d.
    @Test mutating func aStartTrimShorterKeepsTheStart() throws {
        try session.rippleTrim("A", edge: .start, by: 4_800, on: ["a", "b"], naming: [])
        #expect(
            lane("a") == [
                Clip(id: "A", file: "f", start: 48_000, offset: 104_800, length: 43_200),
                Clip(id: "B", file: "f", start: 115_200, offset: 0, length: 24_000),
            ])
        #expect(
            lane("b") == [
                Clip(id: "W", file: "f", start: 0, offset: 0, length: 48_000),
                Clip(id: "W@52800", file: "f", start: 48_000, offset: 52_800, length: 147_200),
            ], "b loses the span after the start")
    }

    /// C11 start longer: the clip start stays, and its offset shrinks by d.
    @Test mutating func aStartTrimLongerKeepsTheStart() throws {
        try session.rippleTrim("A", edge: .start, by: -4_800, on: ["a", "b"], naming: [])
        #expect(
            lane("a") == [
                Clip(id: "A", file: "f", start: 48_000, offset: 95_200, length: 52_800),
                Clip(id: "B", file: "f", start: 124_800, offset: 0, length: 24_000),
            ])
        #expect(
            lane("b") == [
                Clip(id: "W", file: "f", start: 0, offset: 0, length: 48_000),
                Clip(id: "W@48000", file: "f", start: 52_800, offset: 48_000, length: 152_000),
            ], "b gets d of silence at the start")
    }

    /// C11 limits. Control: a limit plus 1 that does not throw, or a throw that leaves a moved clip.
    @Test mutating func theFileLimitsTheTrim() throws {
        var end = session
        try end.rippleTrim("A", edge: .end, by: 332_000, on: ["a", "b"], naming: [])
        #expect(end.clip("A")?.clip.end == 428_000, "an end at the file end passes")
        var start = session
        try start.rippleTrim("A", edge: .start, by: -100_000, on: ["a", "b"], naming: [])
        #expect(start.clip("A")?.clip.offset == 0, "a start at offset 0 passes")
        let before = session
        #expect(throws: SessionError.clipOutsideFile("A"), "one frame past the file end") {
            try session.rippleTrim("A", edge: .end, by: 332_001, on: ["a", "b"], naming: [])
        }
        #expect(throws: SessionError.clipOutsideFile("A"), "offset -1") {
            try session.rippleTrim("A", edge: .start, by: -100_001, on: ["a", "b"], naming: [])
        }
        #expect(throws: SessionError.clipOutsideFile("A"), "no frame left") {
            try session.rippleTrim("A", edge: .end, by: -48_000, on: ["a", "b"], naming: [])
        }
        #expect(throws: SessionError.unknownClip("Z")) {
            try session.rippleTrim("Z", edge: .end, by: 1, on: [], naming: [])
        }
        #expect(session == before, "a refused trim changes nothing")
    }

    /// C11 (plan gate 2 item 3). Control: a start limit with a frame-0 term.
    @Test mutating func aClipAtFrameZeroExtendsItsStart() throws {
        try session.place(Clip(id: "Z", file: "f", start: 0, offset: 4_800, length: 24_000), on: "a")
        var passing = session
        try passing.rippleTrim("Z", edge: .start, by: -4_800, on: ["a", "b"], naming: [])
        #expect(passing.clip("Z")?.clip == Clip(id: "Z", file: "f", start: 0, offset: 0, length: 28_800))
        #expect(passing.clip("A")?.clip.start == 52_800, "the rest moves right by 4 800")
        let before = session
        #expect(throws: SessionError.clipOutsideFile("Z")) {
            try session.rippleTrim("Z", edge: .start, by: -4_801, on: ["a", "b"], naming: [])
        }
        #expect(session == before)
    }

    /// C11. Control: a list without the own track that leaves the own later clips in place.
    @Test func theOwnTrackAlwaysRipples() throws {
        var without = session
        var with = session
        try without.rippleTrim("A", edge: .end, by: -4_800, on: ["b"], naming: [])
        try with.rippleTrim("A", edge: .end, by: -4_800, on: ["a", "b"], naming: [])
        #expect(without == with)
        #expect(without.clip("B")?.clip.start == 115_200)
    }

    /// C11 crossfade at the trimmed edge, each direction: both clips give 0 at that join. Control:
    /// a crossfade kept at the trimmed edge (the start-longer case throws `.crossfadeOutsideFile`).
    @Test(arguments: [(.end, -4_800), (.end, 4_800), (.start, 4_800), (.start, -4_800)] as [(Fades.Edge, Int)])
    func aRippleTrimDropsTheCrossfadeAtTheTrimmedEdge(edge: Fades.Edge, delta: Int) throws {
        var test = try RippleTrimTests()
        // A has offset 4 800, so a start longer by 4 800 reaches offset 0 with no handle for a kept half.
        try test.session.clear(48_000..<96_000, on: ["a"])
        try test.session.place(Clip(id: "A", file: "f", start: 48_000, offset: 4_800, length: 48_000), on: "a")
        try test.session.place(Clip(id: "P", file: "f", start: 24_000, offset: 300_000, length: 24_000), on: "a")
        try test.session.place(Clip(id: "N", file: "f", start: 96_000, offset: 300_000, length: 24_000), on: "a")
        try test.session.setCrossfades([edge == .start ? "P" : "A": 960])
        try test.session.rippleTrim("A", edge: edge, by: Frames(delta), on: ["a", "b"], naming: [])
        #expect(test.allCrossfades.isEmpty, "\(edge) \(delta): the crossfade goes from both clips")
        #expect((try? Session(xml: try test.session.checkedData())) == test.session, "\(edge) \(delta): it saves")
    }

    /// C11 crossfade at the other edge: it keeps its length, and the minimum length is its half.
    /// Control: a trim one frame under the minimum that does not throw.
    @Test mutating func theCrossfadeAtTheOtherEdgeStays() throws {
        try session.place(Clip(id: "N", file: "f", start: 96_000, offset: 300_000, length: 24_000), on: "a")
        try session.setCrossfades(["A": 960])
        let before = session
        #expect(throws: SessionError.fadeOutsideClip("A", length: 479)) {
            try session.rippleTrim("A", edge: .start, by: 47_521, on: ["a", "b"], naming: [])
        }
        #expect(session == before)
        try session.rippleTrim("A", edge: .start, by: 47_520, on: ["a", "b"], naming: [])
        #expect(session.clip("A")?.clip.length == 480, "the minimum passes")
        #expect(
            allCrossfades == ["A": Crossfades(start: 0, end: 960)!, "N": Crossfades(start: 960, end: 0)!],
            "the crossfade at the other edge keeps its length on both clips")
        #expect(session.clip("N")?.clip.start == 48_480, "N moves with the end of A")
    }
}
