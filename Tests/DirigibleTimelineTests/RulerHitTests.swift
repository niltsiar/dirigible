import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Mouse-edits criterion 12: the hit order on the ruler is triangle, flag, then seek. The in point
/// is at x 200 pt (96,000), the out point at x 400 pt; marker m1 is at x 200, chapter m2 at x 300.
struct RulerHitTests {
    let geometry = Fixture.geometry
    let marks = Marks(inPoint: 96_000, outPoint: 192_000, tracks: ["t1"])
    let markers: [MarkerID: Marker] = [
        "m1": Marker(id: "m1", name: "Intro", position: 96_000, kind: .marker),
        "m2": Marker(id: "m2", name: "Part 2", position: 144_000, kind: .chapter),
    ]

    func hit(_ x: Double, _ y: Double) -> RulerHit? {
        RulerGeometry.hit(x, y, markers: markers, marks: marks, geometry: geometry)
    }

    @Test func aTriangleBeatsAFlagAndAFlagBeatsTheSeek() {
        #expect(hit(201, 20) == .triangle(.inPoint), "the triangle band, also in the reach of m1")
        #expect(hit(205, 20) == .triangle(.inPoint))
        #expect(hit(206, 20) == .flag("m1"), "past the triangle, in the box of m1")
        #expect(hit(201, 10) == .flag("m1"), "over the triangle band")
        #expect(hit(197, 10) == .flag("m1"))
        #expect(hit(196.9, 10) == .time(94_512))
        #expect(hit(207, 10) == .time(99_360))
        #expect(hit(399, 23) == .triangle(.outPoint))
        #expect(hit(-5, 10) == nil, "the corner over the track headers")
    }

    /// Two flags in reach: the nearest; at a tie, a marker before a chapter, then the lower ID.
    @Test func theNearestFlagWinsThenAMarkerThenTheLowerID() {
        let markers: [MarkerID: Marker] = [
            "m1": Marker(id: "m1", name: "", position: 96_000, kind: .marker),
            "c1": Marker(id: "c1", name: "", position: 97_440, kind: .chapter),
            "m3": Marker(id: "m3", name: "", position: 480_000, kind: .marker),
            "m2": Marker(id: "m2", name: "", position: 480_000, kind: .marker),
        ]
        func hit(_ x: Double) -> RulerHit? {
            RulerGeometry.hit(x, 10, markers: markers, marks: Marks(), geometry: geometry)
        }

        #expect(hit(202.5) == .flag("c1"), "0.5 pt from c1, 2.5 pt from m1")
        #expect(hit(201.5) == .flag("m1"), "a tie: the marker")
        #expect(hit(1001) == .flag("m2"), "a tie of two markers: the lower ID")
    }
}
