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
