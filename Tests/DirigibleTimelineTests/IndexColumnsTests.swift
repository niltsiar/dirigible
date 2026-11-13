import Testing

@testable import DirigibleTimeline

/// The user columns of the session index list, and the check of the stored value.
struct IndexColumnsTests {
    @Test func noOptionalColumnShowsByDefault() {
        #expect(IndexColumns().shown == [], "no Track column by default")
        #expect(IndexColumns(stored: nil).shown == [])
    }

    @Test func aToggleShowsAndHidesAColumn() {
        var columns = IndexColumns()
        columns.toggle(.duration)
        #expect(columns.shown == [.duration])
        columns.toggle(.track)
        #expect(columns.shown == [.track, .duration])
        columns.toggle(.duration)
        #expect(columns.shown == [.track])
    }

    @Test func theStoredValueKeepsTheColumnsInTheOrderOfTheList() {
        #expect(IndexColumns(shown: [.end, .track]).stored == ["track", "end"])
        #expect(IndexColumns().stored == [])
        for shown in [Set<IndexColumns.Column>(), [.end], [.track, .duration, .end]] {
            #expect(IndexColumns(stored: IndexColumns(shown: shown).stored).shown == shown)
        }
    }

    @Test func aStoredValueOfAnotherShapeGivesTheDefault() {
        #expect(
            IndexColumns(stored: ["duration", "name", "start", "bogus", ""]).shown == [.duration],
            "Name and Start are no choice")
        #expect(IndexColumns(stored: ["duration", "duration"]).shown == [.duration])
        #expect(IndexColumns(stored: "duration").shown == [])
        #expect(IndexColumns(stored: 3).shown == [])
        #expect(IndexColumns(stored: [1, 2]).shown == [])
        #expect(
            IndexColumns(stored: ["track", 2] as [Any]).shown == [], "an array with a non-string is no stored value")
    }
}
