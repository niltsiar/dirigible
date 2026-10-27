import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// A plain click in the range zone of a lane selects its track (F109, decision 0017). The fixture
/// of `GroupGesture`: 480 frames per point, 60 pt lanes t1 to t4. A is x 100 to 200 on t1, B is
/// x 100 to 200 on t2, and t4 has no clip. The move zone of a clip is y 0 to 40 pt of its lane.
struct LaneClickGestureTests {
    var g: GroupGesture

    init() throws { g = try GroupGesture() }

    /// The track selection that a plain click gives: the range of that one track, with no points.
    static func track(_ id: TrackID) -> Selection { .range(Marks(tracks: [id])) }

    /// The first selection effect of `effects`.
    static func selection(_ effects: [GestureEffect]) -> Selection? {
        for case .selection(let selection) in effects { return selection }
        return nil
    }

    /// K2: y 40 of lane 0 is the range zone and gives the track; y 39 is the clip.
    @Test mutating func theRangeZoneEdgeSplitsTrackAndClip() {
        #expect(g.click(150, 40) == [.selection(Self.track("t1")), .seek(72_000)], "y 40")
        #expect(g.click(150, 39) == [.clip("A")], "y 39")
    }

    /// K3: the upper part of a clip box under the grab width of 12 pt selects its track.
    @Test mutating func aClipUnderTheGrabWidthSelectsItsTrack() throws {
        try g.session.place(Clip(id: "N", file: "fa", start: 480_000, offset: 0, length: 5_280), on: "t4")
        try g.session.place(Clip(id: "M", file: "fa", start: 600_000, offset: 0, length: 5_760), on: "t4")

        #expect(Self.selection(g.click(1_005, 190)) == Self.track("t4"), "11 pt")
        #expect(g.click(1_255, 190) == [.clip("M")], "12 pt")
    }

    /// K4: of two selected tracks, a click in a gap of t2 keeps only t2.
    @Test mutating func aClickSelectsOnlyItsTrack() {
        g.selection = .range(Marks(tracks: ["t1", "t2"]))
        #expect(Self.selection(g.click(700, 70)) == Self.track("t2"))
    }

    /// K5: a click clears the in point and the out point of a range.
    @Test mutating func aClickClearsThePointsOfARange() {
        g.selection = .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1", "t2"]))
        #expect(Self.selection(g.click(700, 70)) == Self.track("t2"))
    }

    /// K6: a click replaces a clip set with its track.
    @Test mutating func aClickReplacesAClipSetWithItsTrack() {
        g.selection = GroupGesture.clips(["A"])
        #expect(Self.selection(g.click(700, 70)) == Self.track("t2"))
    }

    /// K9: under 3 pt of movement is a click; at 3 pt it is a range drag with points.
    @Test mutating func underThreePointsIsAClick() {
        _ = g.down(700, 70)
        #expect(Self.selection(g.up(702.9, 70)) == Self.track("t2"), "2.9 pt")

        _ = g.down(700, 70)
        _ = g.drag(703, 70)
        guard case .range(let marks)? = Self.selection(g.up(703, 70)) else {
            Issue.record("no range")
            return
        }
        #expect(marks.inPoint != nil && marks.outPoint != nil, "3 pt")
    }

    /// K15: after a click in a gap of t2, I, O, and a ruler drag make a range on t2 only.
    @Test mutating func aRangeAfterALaneClickUsesItsTrack() throws {
        g.selection = try #require(Self.selection(g.click(700, 70)))
        guard case .range(let marks) = g.selection else {
            Issue.record("no range")
            return
        }
        let ranged = marks.settingIn(48_000, in: g.session).settingOut(144_000, in: g.session)
        #expect(ranged == Marks(inPoint: 48_000, outPoint: 144_000, tracks: ["t2"]), "I and O")

        _ = g.gesture.handle(.down(.ruler(x: 100, y: 10), shift: false, command: false), g.context)
        _ = g.gesture.handle(.drag(.ruler(x: 300, y: 10)), g.context)
        let effects = g.gesture.handle(.up(.ruler(x: 300, y: 10)), g.context)
        #expect(Self.selection(effects) == .range(Marks(inPoint: 48_000, outPoint: 144_000, tracks: ["t2"])))
    }

    /// K19: after a click in a gap of t2, Auto Level takes the clips of t2 only.
    @Test mutating func autoLevelAfterALaneClickUsesItsTrack() throws {
        let selection = try #require(Self.selection(g.click(700, 70)))
        #expect(selection.clipsToLevel(in: g.session) == ["B"])
    }

    /// K20: a double-click below the last lane clears the selection; one click keeps it.
    @Test mutating func aDoubleClickBelowTheLastLaneClearsTheSelection() {
        for selection in [Self.track("t2"), GroupGesture.clips(["A"])] {
            g.selection = selection
            _ = g.gesture.handle(.down(.lanes(x: 150, y: 300), shift: false, command: false, clicks: 2), g.context)
            #expect(g.gesture.handle(.up(.lanes(x: 150, y: 300)), g.context) == [.selection(.none)], "\(selection)")
            #expect(g.click(150, 300) == [], "one click keeps \(selection)")
        }
    }

    /// A press under the last lane starts no range. A drag of 50 pt from there, plain, with
    /// Shift, or with Command, gives no effect, so the selection stays. Control: the same drag in
    /// the gap of t4 makes a range on t4.
    @Test mutating func aDragFromBelowTheLastLaneChangesNoSelection() {
        _ = g.down(150, 230)
        _ = g.drag(200, 230)
        guard case .range(let marks)? = Self.selection(g.up(200, 230)) else {
            Issue.record("the control drag made no range")
            return
        }
        #expect(marks.tracks == ["t4"] && marks.inPoint != nil && marks.outPoint != nil, "the control in t4")

        g.selection = Self.track("t2")
        for (shift, command) in [(false, false), (true, false), (false, true)] {
            var effects = g.gesture.handle(.down(.lanes(x: 150, y: 300), shift: shift, command: command), g.context)
            effects += g.gesture.handle(.drag(.lanes(x: 200, y: 300)), g.context)
            effects += g.gesture.handle(.up(.lanes(x: 200, y: 300)), g.context)
            #expect(effects == [], "Shift \(shift), Command \(command): \(effects)")
        }
    }
}
