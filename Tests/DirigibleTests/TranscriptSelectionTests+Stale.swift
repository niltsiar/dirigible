import AppKit
import DirigibleCore
import DirigibleTimeline
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The pane maps text to frames only with the text of the current session revision (code gate 3,
/// item 1).
extension TranscriptSelectionTests {
    /// After an edit and before the apply of the rebuild, the text is the old one. A key move, a
    /// selection, a click, Return in a header, and Go to Word write no range and no seek then.
    @Test func staleTextWritesNoRangeAndNoSeek() async throws {
        let (model, studio, window, _, pane) = try await shown()
        await base.seek(studio, to: 100_000)
        let thirdPoint = try base.point(at: try #require(pane.shown?.text.units.last).text, in: pane)
        let header = try #require(pane.shown?.text.headers.first).range
        let second = try range("Second", "part", in: pane)
        pane.setSelectedRange(second)
        try #require(model.timeline.selection == Self.range(288_000, 336_000))

        model.run(.deleteCloseGap)
        try #require(pane.shownRevision != studio.sessionRevision, "the rebuild has not applied")
        let (selection, playhead) = (model.timeline.selection, studio.playhead)

        pane.moveSelectionEnd(by: 1)
        #expect(model.timeline.selection == selection, "a key move writes no range")

        pane.setSelectedRange(try range("Hello", "there", in: pane))
        #expect(model.timeline.selection == selection, "a selection writes no range")

        pane.click(at: thirdPoint)
        pane.setSelectedRange(NSRange(location: pane.noticeLength + header.lowerBound, length: 0))
        #expect(window.makeFirstResponder(pane))
        #expect(!pane.returnInHeader(), "Return in a header is not for the pane")
        pane.setSelectedRange(try range("Hello", in: pane))
        #expect(!pane.goToWord(), "Go to Word finds no word")
        await model.settleTransport()
        #expect(studio.playhead == playhead, "no seek")

        await until("the pane applies the rebuild") {
            settle(window)
            return pane.shownRevision == studio.sessionRevision
        }
        pane.click(at: try base.point(at: try #require(pane.shown?.text.units.last).text, in: pane))
        await model.settleTransport()
        #expect(studio.playhead != playhead, "after the apply, a click seeks")
        await model.close()
    }
}
