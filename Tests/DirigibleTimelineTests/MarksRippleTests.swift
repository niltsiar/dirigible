import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// The scope of a ripple (decision 0037, criterion C10) on the small fixture: tracks t1, t2, t3.
struct MarksRippleTests {
    /// Control: the twin scope with all tracks, or the default scope with the selected tracks.
    @Test func theTwinScopeIsTheSelectedTracks() throws {
        let session = try Fixture.session()
        let marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t2"])
        let all = marks.rippleScope(selectedOnly: false, in: session)
        #expect(all?.range == 48_000..<96_000 && all?.tracks == ["t1", "t2", "t3"], "the default: all tracks")
        let twin = marks.rippleScope(selectedOnly: true, in: session)
        #expect(twin?.range == 48_000..<96_000 && twin?.tracks == ["t2"], "the twin: the selected tracks")
        #expect(all?.selected == ["t2"] && twin?.selected == ["t2"], "the excerpt of a Cut")
        #expect(Marks().rippleScope(selectedOnly: false, in: session) == nil, "no selection")
    }

    /// C51 (decision 0073): I and O, `Marks.all`, and tracks by default name no track; a lane drag
    /// over the same tracks names each; a Command-click after I and O names the rest; a twin names
    /// its tracks.
    @Test func aDefaultSelectionNamesNoTrack() throws {
        let session = try Fixture.session()
        let io = Marks().settingIn(48_000, in: session).settingOut(96_000, in: session)
        #expect(io.tracksByDefault && io.rippleScope(selectedOnly: false, in: session)?.named == [])
        #expect(Marks.all(in: session).rippleScope(selectedOnly: false, in: session)?.named == [])
        let lanes = Marks.drag(from: 48_000, to: 96_000, lanes: (0, 2), in: session)
        #expect(!lanes.tracksByDefault)
        #expect(lanes.rippleScope(selectedOnly: false, in: session)?.named == ["t1", "t2", "t3"])
        let toggled = io.toggled("t1")
        #expect(
            !toggled.tracksByDefault && toggled.rippleScope(selectedOnly: false, in: session)?.named == ["t2", "t3"])
        #expect(
            io.rippleScope(selectedOnly: true, in: session)?.named == ["t1", "t2", "t3"], "a twin names its tracks")
    }

    /// C54: the excerpt of a Cut holds only the lanes that cut: with t3 following, I and O leave it
    /// out; with the flag off, or a range drawn on its lane, it is in.
    @Test func theExcerptHoldsOnlyTheLanesThatCut() throws {
        var session = try Fixture.session()
        let io = Marks().settingIn(48_000, in: session).settingOut(96_000, in: session)
        #expect(io.rippleScope(selectedOnly: false, in: session)?.selected == ["t1", "t2", "t3"], "the flag off")
        try session.setFollowTrack(true, tracks: ["t3"])
        #expect(io.rippleScope(selectedOnly: false, in: session)?.selected == ["t1", "t2"])
        let lane = Marks.drag(from: 48_000, to: 96_000, lanes: (2, 2), in: session)
        #expect(lane.rippleScope(selectedOnly: false, in: session)?.selected == ["t3"])
    }

    /// Code gate 3 item 1: a Copy takes the lanes of a Cut of the same range, so I and O leave the
    /// follow track t3 out, a range on its lane copies it, and with each track following a default
    /// range copies nothing.
    @Test func aCopyTakesTheLanesOfACut() throws {
        var session = try Fixture.session()
        let io = Marks().settingIn(48_000, in: session).settingOut(96_000, in: session)
        let sources = { (marks: Marks, session: Session) in
            try Selection.range(marks).excerpt(in: session)?.lanes.map(\.source)
        }
        #expect(try sources(io, session) == ["t1", "t2", "t3"], "the flag off")
        try session.setFollowTrack(true, tracks: ["t3"])
        #expect(try sources(io, session) == ["t1", "t2"])
        let lane = Marks.drag(from: 48_000, to: 96_000, lanes: (2, 2), in: session)
        #expect(try sources(lane, session) == ["t3"])
        try session.setFollowTrack(true, tracks: ["t1", "t2"])
        #expect(try sources(io, session) == nil, "no lane cuts, as a Cut refuses")
    }
}
