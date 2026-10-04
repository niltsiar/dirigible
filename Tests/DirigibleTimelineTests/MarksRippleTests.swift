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
}
