import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Multi-clip-selection: the window selection is a range or a clip set (decision 0038).
struct SelectionTests {
    @Test func noneIsAnEmptyRange() {
        #expect(Selection.none == .range(Marks()))
        #expect(Selection.none.marks == Marks())
    }

    @Test func clipSetIsNeverEmpty() throws {
        #expect(ClipSet(Set()) == nil)
        let set = try #require(ClipSet(["A"]))
        #expect(set.ids == ["A"])
        #expect(Selection.clips(set).marks == nil, "a clip set has no range")
    }
}

/// The reads of a selection (decision 0038), on the fixture of `GroupGesture`.
struct SelectionReadTests {
    let session: Session

    init() throws { session = try GroupGesture().session }

    func ids(_ selection: Selection) -> [ClipID] { selection.selectedClips(in: session).map(\.clip.id) }

    @Test func selectedClipsForBothKinds() {
        #expect(ids(GroupGesture.clips(["D", "A"])) == ["A", "D"], "session order")
        #expect(GroupGesture.clips(["D"]).selectedClips(in: session).map(\.lane) == [2])
        #expect(ids(.range(Marks(inPoint: 48_000, outPoint: 200_000, tracks: ["t1", "t2"]))) == ["A", "C", "B"])
        #expect(ids(.range(Marks(inPoint: 50_000, outPoint: 200_000, tracks: ["t1"]))) == ["C"], "held whole only")
        #expect(ids(.none) == [])
    }

    @Test func staleIDsDropAtTheRead() {
        #expect(ids(GroupGesture.clips(["A", "gone"])) == ["A"])
    }

    @Test func togglingFromARangeAndFromASet() {
        let range = Selection.range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1", "t2"]))
        #expect(range.toggling("D", in: session) == GroupGesture.clips(["A", "B", "D"]))
        #expect(range.toggling("A", in: session) == GroupGesture.clips(["B"]))
        #expect(GroupGesture.clips(["A", "gone"]).toggling("A", in: session) == .none, "a stale ID drops")
    }
}
