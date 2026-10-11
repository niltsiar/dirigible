import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Timeline-navigation criterion N1: the strip maps the whole session (max(end, 10 s) + 2%) to its
/// width; the view frame is at least 6 pt wide; the edge zones need a frame of 16 pt.
struct OverviewGeometryTests {
    static let twoHours = Frames(48_000 * 7200)
    static let strip = OverviewGeometry(width: 1440, end: twoHours, rate: 48_000)

    /// A view of `points` of overview from x 100.
    static func view(points: Double, at x: Double = 100) -> Viewport {
        Viewport(
            scale: TimelineScale(framesPerPoint: points * 244_800 / 1440), origin: x * 244_800, width: 1440,
            end: twoHours, rate: 48_000)
    }

    @Test func theStripMapsTheSessionToItsWidth() {
        #expect(Self.strip.framesPerPoint == 244_800, "244800 frames per point")
        #expect(Self.strip.x(of: 0) == 0, "frame 0 is x 0")
        #expect(Self.strip.frame(at: 10) == 2_448_000, "x 10 is frame 2448000")
        #expect(Self.strip.frame(at: -5) == 0, "x before 0 is frame 0")
    }

    /// Origin 1,000,000 and 737,280 frames in view: x 4.085 to 7.097, drawn 6 pt wide on its center.
    @Test func theViewFrameIsAtLeastSixPoints() {
        let view = Viewport(
            scale: TimelineScale(framesPerPoint: 512), origin: 1_000_000, width: 1440, end: Self.twoHours,
            rate: 48_000)
        #expect(abs(Self.strip.x(of: 1_000_000) - 4.085) < 0.001)
        #expect(abs(Self.strip.x(of: 1_737_280) - 7.097) < 0.001)
        let frame = Self.strip.viewFrame(view)
        #expect(frame.width == 6, "the view frame is at least 6 pt")
        #expect(abs(frame.minX - 2.591) < 0.001, "the drawn frame is on the true center")
        #expect(frame.height == OverviewGeometry.height)
        #expect(Self.strip.viewFrame(Self.view(points: 40)) == Rect(x: 100, y: 0, width: 40, height: 28))
    }

    /// Wider lanes at one zoom show more frames than the session: the drawn frame stays in the strip,
    /// and the edge zones move to the drawn edge.
    @Test func theViewFrameStaysInTheStrip() {
        let wide = Self.view(points: 1600, at: 0)
        #expect(Self.strip.viewFrame(wide) == Rect(x: 0, y: 0, width: 1440, height: 28))
        #expect(Self.strip.hit(1438, wide) == .trailingEdge, "the trailing zone is at the strip end")
        #expect(Self.strip.viewFrame(Self.view(points: 300, at: 1200)) == Rect(x: 1200, y: 0, width: 240, height: 28))
        let last = Self.view(points: 0.75, at: 1439.25)
        #expect(Self.strip.viewFrame(last) == Rect(x: 1434, y: 0, width: 6, height: 28), "6 pt on the last page")
        let first = Self.view(points: 0.75, at: 0)
        #expect(Self.strip.viewFrame(first) == Rect(x: 0, y: 0, width: 6, height: 28), "6 pt at the start")
        for points in [0.5, 3, 40, 1439, 1500, 3000] {
            for x in stride(from: -10.0, through: 1450, by: 7.25) {
                let frame = Self.strip.viewFrame(Self.view(points: points, at: x))
                #expect(frame.minX >= 0 && frame.maxX <= 1440 && frame.width >= 6, "\(points) pt at x \(x)")
            }
        }
    }

    /// U9: each edge zone takes 3 pt out and 3 pt in, only on a frame of 16 pt or more.
    @Test func theEdgesNeedSixteenPoints() {
        let wide = Self.view(points: 40)
        #expect(Self.strip.hit(96, wide) == .outside)
        #expect(Self.strip.hit(98, wide) == .leadingEdge, "2 pt outside the edge is the edge")
        #expect(Self.strip.hit(102, wide) == .leadingEdge)
        #expect(Self.strip.hit(104, wide) == .body, "4 pt inside is the body")
        #expect(Self.strip.hit(136, wide) == .body, "4 pt inside is the body")
        #expect(Self.strip.hit(138, wide) == .trailingEdge)
        #expect(Self.strip.hit(142, wide) == .trailingEdge, "2 pt outside the edge is the edge")
        #expect(Self.strip.hit(144, wide) == .outside)
        #expect(Self.strip.hit(101, Self.view(points: 12)) == .body, "a 12 pt frame has no edge")
        #expect(Self.strip.hit(98, Self.view(points: 12)) == .outside, "a 12 pt frame has no edge")
        #expect(Self.strip.hit(101, Self.view(points: 20)) == .leadingEdge, "a 20 pt frame has edges")
    }

    /// Code gate 1 item 8: one method gives the edge zones that the hit test and the grips use.
    @Test func theEdgeZonesComeFromOneMethod() throws {
        let zones = try #require(Self.strip.edgeZones(Self.view(points: 40)))
        #expect(
            [zones.leading.minX, zones.leading.maxX, zones.trailing.minX, zones.trailing.maxX] == [97, 103, 137, 143])
        #expect(zones.leading.height == OverviewGeometry.height && zones.trailing.y == 0)
        #expect(Self.strip.edgeZones(Self.view(points: 15.9)) == nil, "a frame under 16 pt has no zone")
        #expect(Self.strip.edgeZones(Self.view(points: 16)) != nil)
    }
}

/// Criterion N2: merged column spans per row, at most one row per 2 px, and the ticks, the band,
/// and the tint. The extent is 288,000 frames on 2,880 columns: 100 frames per column.
struct OverviewPlanTests {
    static func session(tracks: Int, clips: [Clip] = []) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 400_000_000))
        for n in 0..<tracks { try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono) }
        for clip in clips { try session.place(clip, on: "t0") }
        return session
    }

    static func clip(_ id: String, _ range: Range<Int>) -> Clip {
        Clip(id: ClipID(id), file: "f", start: Frames(range.lowerBound), offset: 0, length: Frames(range.count))
    }

    static func plan(_ session: Session, height: Int = 56, selected: [Int] = [], selection: Range<Frames>? = nil)
        -> OverviewPlan
    {
        OverviewPlan(
            OverviewInputs(session: session, selection: selection, selectedLanes: selected, extent: 288_000),
            columns: 2880, height: height)
    }

    @Test func clipsMergeByColumn() throws {
        let session = try Self.session(
            tracks: 1,
            clips: [
                Self.clip("a", 0..<1000), Self.clip("b", 1050..<2000), Self.clip("c", 5000..<5001),
                Self.clip("d", 10_000..<11_000), Self.clip("e", 11_250..<12_000),
            ])
        let spans = Self.plan(session).clips[0]
        #expect(spans.first == 0..<20, "adjacent clips give one span")
        #expect(spans.contains(50..<51), "a 1-frame clip is one column")
        #expect(spans.suffix(2) == [100..<110, 112..<120], "a gap of two columns shows")
    }

    /// 2,000 clips per track at 2 h on 2,880 columns (the 2 h fixture of the benchmarks, one split
    /// call): at most 2,880 columns per row, and each clip covers a column.
    @Test func twoThousandClipsFitTheColumns() throws {
        let frames = 345_600_000
        var session = try Self.session(tracks: 1, clips: [Self.clip("c", 0..<frames)])
        _ = try session.splitClips(at: (1..<2000).map { Frames($0 * frames / 2000) }, on: ["t0"])
        #expect(session.tracks[0].clips.count == 2000)
        let plan = OverviewPlan(
            OverviewInputs(session: session, selection: nil, selectedLanes: [], extent: 352_512_000), columns: 2880,
            height: 56)
        let covered = plan.clips[0].reduce(0) { $0 + $1.count }
        #expect(covered <= 2880)
        let columns = Set(plan.clips[0].flatMap { $0 })
        #expect(
            session.tracks[0].clips.allSatisfy { columns.contains(Int(Double($0.start.count) * 2880 / 352_512_000)) })
    }

    /// Plan gate item 7: at most floor(56 / 2) = 28 rows; a 1 px gap only when each row keeps 2 px.
    @Test func rowsKeepTwoPixels() throws {
        let six = Self.plan(try Self.session(tracks: 6)).rows
        #expect(six == [0..<8, 9..<17, 18..<26, 27..<35, 36..<44, 45..<53], "a 1 px gap between rows")
        let eighteen = Self.plan(try Self.session(tracks: 18)).rows
        #expect(eighteen.count == 18 && eighteen[1] == 3..<5, "a 1 px gap between rows")
        let sixty = Self.plan(try Self.session(tracks: 60))
        #expect(sixty.rows.count == 28, "60 tracks give 28 rows")
        #expect(sixty.rows[1] == 2..<4, "no gap when a row keeps under 2 px")
        #expect(sixty.clips.count == 28, "60 tracks give 28 rows")
    }

    /// A strip at scale 1 is 28 px: 3 tracks give 3 rows of 8 px with 1 px gaps, 60 tracks 14 rows
    /// of 2 px with no gap, and the ticks keep a quarter and a half of the height.
    @Test func aScaleOneStripKeepsTheRules() throws {
        var session = try Self.session(tracks: 3)
        try session.setMarker(Marker(id: "m", name: "M", position: 10_000, kind: .marker))
        try session.setMarker(Marker(id: "c", name: "C", position: 20_000, kind: .chapter))
        let three = Self.plan(session, height: 28)
        #expect(three.rows == [0..<8, 9..<17, 18..<26], "a 1 px gap between rows")
        #expect(three.ticks.map(\.rows) == [0..<7, 0..<14], "a chapter tick is longer than a marker tick")
        let sixty = Self.plan(try Self.session(tracks: 60), height: 28).rows
        #expect(sixty.count == 14 && sixty[1] == 2..<4, "no gap when a row keeps under 2 px")
    }

    @Test func sixtyTracksMergeInOrder() throws {
        var session = try Self.session(tracks: 60)
        try session.place(Self.clip("x", 1000..<2000), on: "t59")
        try session.place(Self.clip("y", 3000..<4000), on: "t58")
        let plan = Self.plan(session, selected: [59])
        #expect(plan.clips[27] == [10..<20, 30..<40], "tracks 58 and 59 share the last row")
        #expect(plan.tinted == [27], "the row of a selected lane is tinted")
    }

    @Test func ticksBandAndTint() throws {
        var session = try Self.session(tracks: 6)
        try session.setMarker(Marker(id: "m", name: "M", position: 10_000, kind: .marker))
        try session.setMarker(Marker(id: "c", name: "C", position: 20_000, kind: .chapter))
        let plan = Self.plan(session, selected: [1, 4], selection: 5_000..<6_000)
        #expect(plan.ticks.map(\.column) == [100, 200])
        let marker = try #require(plan.ticks.first { $0.kind == .marker })
        let chapter = try #require(plan.ticks.first { $0.kind == .chapter })
        #expect(chapter.rows.count > marker.rows.count, "a chapter tick is longer than a marker tick")
        #expect(plan.band == 50..<60)
        #expect(plan.tinted == [1, 4])
    }
}

/// Criterion N3: the states x events table of the run design, one test per cell that changes the
/// state. The strip is 1440 pt for 2 h (244,800 frames per point); the view is 40 pt of overview
/// at x 100 (origin 24,480,000, 9,792,000 frames, 6,800 frames per point).
struct OverviewGestureTests {
    static let strip = OverviewGeometryTests.strip
    static let view = OverviewGeometryTests.view(points: 40)
    var gesture = OverviewGesture()

    mutating func send(_ event: OverviewEvent, _ view: Viewport = view) -> NavigationInput? {
        gesture.handle(event, Self.strip, view)
    }

    @Test mutating func aPressOutsideCentersAndThenScrolls() {
        #expect(send(.down(x: 500, clicks: 1)) == .center(122_400_000))
        #expect(gesture.isActive)
        #expect(send(.drag(x: 510)) == .scroll(to: 119_952_000), "the grab is at the center")
        #expect(send(.up(x: 510)) == .scroll(to: 119_952_000))
        #expect(!gesture.isActive)
    }

    @Test mutating func aBodyDragScrollsByTheDragDistance() {
        #expect(send(.down(x: 120, clicks: 1)) == nil)
        #expect(send(.drag(x: 122)) == nil, "2 pt is a click")
        #expect(send(.drag(x: 124)) == .scroll(to: 25_459_200), "4 pt is a drag")
        #expect(send(.drag(x: 130)) == .scroll(to: 26_928_000), "a 10 pt drag moves 10 x 244800 frames")
        #expect(send(.escape) == .scroll(to: 24_480_000), "Esc gives the origin of the mouse-down")
        #expect(!gesture.isActive)
    }

    @Test mutating func aClickOnTheFrameCentersThere() {
        #expect(send(.down(x: 120, clicks: 1)) == nil)
        #expect(send(.drag(x: 121)) == nil, "2 pt is a click")
        #expect(send(.up(x: 121)) == .center(29_620_800))
        #expect(!gesture.isActive)
    }

    @Test mutating func anEscapeBeforeTheDragDoesNothing() {
        _ = send(.down(x: 120, clicks: 1))
        #expect(send(.escape) == nil)
        #expect(!gesture.isActive)
        #expect(send(.up(x: 120)) == nil)
    }

    /// The trailing edge moves and the leading edge stays; the moving edge stops at the fixed edge
    /// plus the closest zoom (128 frames per point x 1440 pt).
    @Test mutating func aTrailingEdgeDragZooms() {
        #expect(send(.down(x: 140, clicks: 1)) == nil)
        let zoom = { (points: Double, origin: Double) in
            Zoom(scale: TimelineScale(framesPerPoint: points), origin: origin)
        }
        #expect(send(.drag(x: 150)) == .zoomTo(zoom(8500, 24_480_000), stroke: .began))
        #expect(send(.drag(x: 160)) == .zoomTo(zoom(10_200, 24_480_000), stroke: .changed))
        #expect(send(.drag(x: 50)) == .zoomTo(zoom(128, 24_480_000), stroke: .changed))
        #expect(send(.up(x: 160)) == .zoomTo(zoom(10_200, 24_480_000), stroke: .ended))
        #expect(!gesture.isActive)
    }

    @Test mutating func aLeadingEdgeDragZooms() {
        #expect(send(.down(x: 100, clicks: 1)) == nil)
        let expected = Zoom(scale: TimelineScale(framesPerPoint: 8500), origin: 22_032_000)
        #expect(send(.drag(x: 90)) == .zoomTo(expected, stroke: .began))
        #expect(send(.escape) == .zoomTo(Self.view.zoom, stroke: .cancelled), "Esc gives the view of the mouse-down")
        #expect(!gesture.isActive)
    }

    @Test mutating func anEdgePressWithNoDragCenters() {
        _ = send(.down(x: 140, clicks: 1))
        #expect(send(.up(x: 141)) == .center(34_516_800))
    }

    /// U10 and plan gate item 1: the first click already centered the view, so the double-click
    /// carries the view of the first click.
    @Test mutating func aDoubleClickTogglesTheFitWithTheViewOfTheFirstClick() {
        #expect(send(.down(x: 500, clicks: 1)) == .center(122_400_000))
        _ = send(.up(x: 500))
        let centered = Viewport(
            scale: Self.view.scale, origin: 117_504_000, width: 1440, end: OverviewGeometryTests.twoHours, rate: 48_000)
        #expect(
            send(.down(x: 500, clicks: 2), centered) == .toggleFit(before: Self.view.zoom),
            "the double-click carries the view of the first click")
        #expect(!gesture.isActive)
        #expect(send(.up(x: 500), centered) == nil)
    }

    @Test mutating func aNewPressResetsTheGesture() {
        _ = send(.down(x: 120, clicks: 1))
        _ = send(.drag(x: 130))
        #expect(send(.down(x: 500, clicks: 1)) == .center(122_400_000))
        #expect(send(.drag(x: 510)) == .scroll(to: 119_952_000))
    }

    /// U9: a frame of 4 pt (drawn 6 pt) is all body, so a drag from its center scrolls.
    @Test mutating func aPressAtTheFrameCenterScrollsAtEditZoom() {
        let edit = Viewport(
            scale: TimelineScale(framesPerPoint: 512), origin: 1_000_000, width: 1440,
            end: OverviewGeometryTests.twoHours, rate: 48_000)
        #expect(send(.down(x: 5.591, clicks: 1), edit) == nil)
        let scrolled = send(.drag(x: 15.591), edit)
        guard case .scroll(let origin) = scrolled else {
            Issue.record("a drag from the center scrolls: \(String(describing: scrolled))")
            return
        }
        #expect(abs(origin - 3_448_000) < 1)
    }

    @Test mutating func theCursorsFollowTheZones() {
        #expect(gesture.cursor(at: 100, Self.strip, Self.view) == .resizeLeftRight)
        #expect(gesture.cursor(at: 120, Self.strip, Self.view) == .openHand)
        #expect(gesture.cursor(at: 500, Self.strip, Self.view) == .arrow)
        _ = send(.down(x: 120, clicks: 1))
        _ = send(.drag(x: 130))
        #expect(gesture.cursor(at: 500, Self.strip, Self.view) == .closedHand)
    }
}
