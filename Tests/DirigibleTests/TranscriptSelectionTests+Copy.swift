import AppKit
import DirigibleCore
import DirigibleTimeline
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Copy, Cut, and Delete from each start state (criteria P10, P16).
extension TranscriptSelectionTests {
    /// A window with a split take, so the studio refuses a ripple (decision 0037): track t1 holds the
    /// first segment of the take, with the words "Hi you" on it, and the pane shows them with both
    /// words selected.
    func splitTakePane(_ take: UnplacedBannerTests) async throws -> (SessionWindow, Studio, TranscriptTextView) {
        let (model, studio) = try await take.open()
        _ = try await take.unplacedTake(model, studio)
        await model.place(UnplacedBannerTests.first, atPlayhead: false)
        try #require(studio.unplacedSegments == [UnplacedBannerTests.second])
        let clip = try #require(studio.session.track("t1")?.clips.first)
        let (clipStart, third) = (clip.start, Double(clip.length.count) / 48_000 / 3)
        let file = try Self.transcript([(0, third, "Hi"), (third, 2 * third, "you")])
        _ = try studio.edit(ripple: false) { session throws(SessionError) in
            try session.importTranscript(file, name: "Take", track: "t1", at: clipStart)
        }
        model.showTranscript()
        let window = try #require(model.window)
        await until(limit: .seconds(10), "the pane shows the words of the take") {
            settle(window)
            guard let pane = TranscriptPaneTests.find(window.contentView) else { return false }
            return pane.shownRevision == pane.builtRevision && pane.shown?.text.units.count == 2
        }
        let pane = try #require(TranscriptPaneTests.find(window.contentView))
        let units = try #require(pane.shown?.text.units)
        let start = units[0].text.lowerBound
        pane.setSelectedRange(NSRange(location: pane.noticeLength + start, length: units[1].text.upperBound - start))
        try #require(model.timeline.selection.marks != nil)
        return (model, studio, pane)
    }

    /// A pasteboard of the test for the text of the pane (P16).
    func ownBoard(for pane: TranscriptTextView) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        pane.pasteboard = board
        return board
    }

    func copyKey(_ window: NSWindow) { app.timeline(.copy, event: key(.keyDown, "c", code: 8, in: window), in: window) }
    func cutKey(_ window: NSWindow) { app.timeline(.cut, event: key(.keyDown, "x", code: 7, in: window), in: window) }

    /// Waits until the pane shows the text of the current session revision.
    func untilRebuilt(_ pane: TranscriptTextView, _ studio: Studio, _ window: NSWindow) async {
        await until(limit: .seconds(10), "the pane shows the new text") {
            settle(window)
            return pane.builtRevision == studio.sessionRevision && pane.shownRevision == pane.builtRevision
        }
    }

    /// P16: Copy with the focus in the pane puts the range on the app clipboard, as a lanes Copy of
    /// the same range does, and changes no session, range, or pane selection.
    @Test func copyCopiesTheRange() async throws {
        let (model, studio, window, _, pane) = try await shown()
        let board = ownBoard(for: pane)
        defer { board.releaseGlobally() }
        let secondPart = try range("Second", "part", in: pane)
        pane.setSelectedRange(secondPart)
        let lanesCopy = try model.timeline.selection.excerpt(in: studio.session)
        let before = studio.session

        copyKey(window)

        #expect(app.clipboard?.excerpt == lanesCopy)
        #expect(studio.session == before, "Copy makes no edit")
        #expect(model.timeline.selection == Self.range(288_000, 336_000))
        #expect(pane.selectedRange() == secondPart)
        await model.close()
    }

    /// P16 (a) to (d): the text of the tinted units goes to the pasteboard for a pane selection and
    /// for a lanes range; with no range nothing changes; a range with no unit copies the range and
    /// keeps the pasteboard.
    @Test func copyWritesTheText() async throws {
        let (model, studio, window, _, pane) = try await shown()
        let board = ownBoard(for: pane)
        defer { board.releaseGlobally() }

        // (a) A pane selection over a header: a line break, no header.
        pane.setSelectedRange(try range("there", "Second", in: pane))
        copyKey(window)
        #expect(board.string(forType: .string) == "there\nSecond")
        #expect(app.clipboard?.excerpt == (try model.timeline.selection.excerpt(in: studio.session)))

        // (b) A lanes range on t1 with no pane selection: the tinted units.
        let lanes = Selection.range(Marks(inPoint: 280_000, outPoint: 324_001, tracks: ["t1"]))
        model.timeline.selection = lanes
        await until(limit: .seconds(10), "the lanes range clears the pane selection") {
            settle(window)
            return pane.selectedRange().length == 0
        }
        copyKey(window)
        #expect(board.string(forType: .string) == "Second part")
        #expect(app.clipboard?.excerpt == (try lanes.excerpt(in: studio.session)))

        // (c) No range.
        model.timeline.selection = .none
        var (count, clipboard) = (board.changeCount, app.clipboard)
        copyKey(window)
        #expect(board.changeCount == count, "no range: no text")
        #expect(app.clipboard == clipboard, "and no copy")

        // (d) A range in the gap after "part": the range copies, the text stays.
        let gap = Self.range(400_000, 500_000)
        model.timeline.selection = gap
        (count, clipboard) = (board.changeCount, app.clipboard)
        copyKey(window)
        #expect(app.clipboard?.excerpt == (try gap.excerpt(in: studio.session)))
        #expect(app.clipboard != clipboard)
        #expect(board.changeCount == count, "no unit: no text")
        await model.close()
    }

    /// P10, P16: Cut writes the text of the range as it was before the ripple, for a pane selection
    /// and for a lanes range; no range and a refused ripple (a split take) write nothing.
    @Test func cutWritesTheText() async throws {
        let (model, studio, window, _, pane) = try await shown()
        let board = ownBoard(for: pane)
        defer { board.releaseGlobally() }

        pane.setSelectedRange(try range("there", "Second", in: pane))
        cutKey(window)
        #expect(board.string(forType: .string) == "there\nSecond")
        #expect(studio.session.words().map(\.text) == ["Hello", "part", "Third"], "the ripple ran")

        await untilRebuilt(pane, studio, window)
        let third = try #require(pane.shown?.text.units.last).frames
        model.timeline.selection = .range(
            Marks(inPoint: third.lowerBound, outPoint: third.upperBound, tracks: Self.tracks))
        cutKey(window)
        #expect(board.string(forType: .string) == "Third", "a lanes range")
        #expect(studio.session.words().map(\.text) == ["Hello", "part"])

        await untilRebuilt(pane, studio, window)
        model.timeline.selection = .none
        var count = board.changeCount
        cutKey(window)
        #expect(board.changeCount == count, "no range: no text")
        await model.close()

        let take = try UnplacedBannerTests()
        let (takeModel, takeStudio, takePane) = try await splitTakePane(take)
        let takeBoard = ownBoard(for: takePane)
        defer { takeBoard.releaseGlobally() }
        var beeps = 0
        takeModel.beep = { beeps += 1 }
        let (session, clipboard) = (takeStudio.session, take.app.clipboard)
        count = takeBoard.changeCount
        takePane.cut(nil)
        #expect(beeps == 1, "a split take refuses the ripple")
        #expect(takeStudio.session == session)
        #expect(takeBoard.changeCount == count, "a refused Cut writes no text")
        #expect(take.app.clipboard == clipboard)
        await takeModel.close()
    }

    /// P10: Delete in the pane with no range beeps and changes nothing; under a split take it beeps
    /// and ripples nothing; during a take it changes nothing.
    @Test func deleteFromEachState() async throws {
        let (model, studio, _, _, pane) = try await shown()
        var beeps = 0
        model.beep = { beeps += 1 }
        pane.setSelectedRange(NSRange(location: try range("Second", in: pane).location, length: 0))
        try #require(model.timeline.selection == .none)
        let before = studio.session
        pane.delete(nil)
        #expect(beeps == 1, "no range: a beep")
        #expect(studio.session == before)
        await model.close()

        let take = try UnplacedBannerTests()
        let (takeModel, takeStudio, takePane) = try await splitTakePane(take)
        var takeBeeps = 0
        takeModel.beep = { takeBeeps += 1 }
        let split = takeStudio.session
        takePane.delete(nil)
        #expect(takeBeeps == 1, "a split take: a beep")
        #expect(takeStudio.session == split, "and no ripple")

        await takeModel.record()
        await take.hal.feed(seconds: 0.2)
        takePane.delete(nil)
        #expect(takeStudio.session.words().map(\.text) == ["Hi", "you"], "during a take: no change")
        #expect(takeBeeps == 1, "and no beep")
        await takeModel.stop()
        await until("the finalize ends") { takeStudio.transport == .idle }
        await takeModel.close()
    }

    /// P16, P10: Copy and Cut with the focus in the lanes write no text, also when the pane shows a
    /// selection.
    @Test func lanesCopyWritesNoText() async throws {
        let (model, studio, window, view, pane) = try await shown()
        let board = ownBoard(for: pane)
        defer { board.releaseGlobally() }
        pane.setSelectedRange(try range("Second", "part", in: pane))
        #expect(window.makeFirstResponder(view.lanes))
        let count = board.changeCount

        copyKey(window)
        #expect(app.clipboard != nil, "the lanes Copy ran")
        #expect(board.changeCount == count, "a lanes Copy writes no text")

        cutKey(window)
        #expect(studio.session.words().map(\.text) == ["Hello", "there", "Third"], "the lanes Cut ran")
        #expect(board.changeCount == count, "a lanes Cut writes no text")
        await model.close()
    }
}
