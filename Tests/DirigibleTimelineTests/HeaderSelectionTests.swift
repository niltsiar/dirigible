import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// A click on a track header selects tracks (ui-polish C10 to C13). The fixture has t1, t2, and t3.
struct HeaderSelectionTests {
    let session: Session
    let set = Selection.clips(ClipSet(["A"])!)

    init() throws { session = try Fixture.session() }

    func click(_ track: TrackID, from selection: Selection, command: Bool = false, shift: Bool = false) -> Selection {
        selection.clickingHeader(track, command: command, shift: shift, in: session)
    }

    @Test func aClickFromNoSelectionSelectsTheTrack() {
        #expect(click("t2", from: .none) == .range(Marks(tracks: ["t2"])))
    }

    @Test func aClickKeepsThePointsOfARange() {
        let range = Selection.range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        #expect(click("t2", from: range) == .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t2"])))
    }

    @Test func aClickReplacesAClipSet() {
        #expect(click("t2", from: set) == .range(Marks(tracks: ["t2"])))
    }

    @Test func aCommandClickTogglesTheTrack() {
        let two = Selection.range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1", "t2"]))
        #expect(
            click("t2", from: two, command: true) == .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])))
        #expect(click("t1", from: .range(Marks(tracks: ["t1"])), command: true) == .none)
        #expect(click("t2", from: set, command: true) == .range(Marks(tracks: ["t2"])))
    }

    @Test func aShiftClickSpansTheTracks() {
        let one = Selection.range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        #expect(
            click("t3", from: one, shift: true)
                == .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1", "t2", "t3"])))
        #expect(click("t3", from: .none, shift: true) == .range(Marks(tracks: ["t3"])))
        #expect(
            click("t1", from: .range(Marks(tracks: ["t3"])), shift: true) == .range(Marks(tracks: ["t1", "t2", "t3"])))
        #expect(click("t2", from: set, shift: true) == .range(Marks(tracks: ["t2"])))
    }

    @Test func headerTracksAreTheTrackPicksOfARange() {
        #expect(Selection.range(Marks(tracks: ["t1", "t3"])).headerTracks(in: session) == ["t1", "t3"])
        #expect(
            Selection.range(Marks(inPoint: 0, outPoint: 10, tracks: ["t2", "gone"])).headerTracks(in: session)
                == ["t2"])
        #expect(set.headerTracks(in: session) == [], "a clip set selects no header (0038)")
        #expect(Selection.none.headerTracks(in: session) == [])
    }
}
