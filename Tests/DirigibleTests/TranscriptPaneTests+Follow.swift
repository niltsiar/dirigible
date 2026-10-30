import AppKit
import DirigibleCore
import DirigibleTimeline
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The click to seek and Return in a header (run transcript-1, landing 2, criteria P5, P21).
extension TranscriptPaneTests {
    /// The point of the first character of the text range `range`, in the coordinates of the pane.
    func point(at range: Range<Int>, in pane: TranscriptTextView) throws -> NSPoint {
        let segment = try #require(try segments(of: range, in: pane).first)
        return NSPoint(x: segment.minX + 1, y: segment.midY)
    }

    /// P5: a click on a unit puts the playhead at its start. A stopped play stays stopped, a play
    /// goes on from the unit start, and the lanes range stays.
    @Test func clickSeeksFromEachState() async throws {
        let (model, studio, _, pane) = try await opened("click")
        let units = try #require(pane.shown).text.units
        let part = try #require(units.first { $0.frames.lowerBound == 312_000 })
        let range = model.timeline.selection

        pane.click(at: try point(at: part.text, in: pane))
        await model.settleTransport()
        #expect(studio.playhead == part.frames.lowerBound)
        #expect(studio.playback == .stopped)
        #expect(model.timeline.selection == range, "a plain click makes no range")

        let third = try #require(units.last)
        model.transport(.playStop)
        await model.settleTransport()
        try #require(studio.playback != .stopped, "the play started")
        pane.click(at: try point(at: third.text, in: pane))
        await model.settleTransport()
        #expect(studio.playback != .stopped, "the play goes on")
        let from = third.frames.lowerBound
        #expect(studio.playhead >= from && studio.playhead < from + 48_000, "the play goes on from the unit")
        await model.close()
    }

    /// P5: a click on a header or in the space after a paragraph does not seek.
    @Test func clickOnAHeaderDoesNotSeek() async throws {
        let (model, studio, _, pane) = try await opened("header")
        let text = try #require(pane.shown).text
        let header = try #require(text.headers.first)
        await seek(studio, to: Self.second)

        pane.click(at: try point(at: header.range, in: pane))
        let unit = try secondUnit(pane)
        let line = try #require(try segments(of: unit.text, in: pane).first)
        pane.click(at: NSPoint(x: pane.bounds.maxX - 4, y: line.midY))
        await model.settleTransport()

        #expect(studio.playhead == Self.second)
        await model.close()
    }

    /// Puts the insertion point at the text location `location` of the value and sends Return as
    /// the menu key does.
    func pressReturn(
        at location: Int, _ model: SessionWindow, _ window: NSWindow, _ pane: TranscriptTextView
    ) async {
        #expect(window.makeFirstResponder(pane), "the pane has the focus")
        pane.setSelectedRange(NSRange(location: pane.noticeLength + location, length: 0))
        app.key = model
        app.timeline(.renameTrack, event: key(.keyDown, "\r", code: 36, in: window), in: window)
        await model.settleTransport()
    }

    /// P21: Return in a header puts the playhead at the first unit of its paragraph. A stopped play
    /// stays stopped and a play goes on. The key renames no track.
    @Test func returnOnAHeaderSeeksFromEachState() async throws {
        let (model, studio, window, pane) = try await opened("return")
        let text = try #require(pane.shown).text
        try #require(text.headers.count == 3)
        model.clickHeader("t1", flags: [])

        await pressReturn(at: text.headers[2].range.lowerBound + 1, model, window, pane)
        #expect(studio.playhead == text.units[4].frames.lowerBound, "paragraph 3")
        #expect(studio.playback == .stopped)
        #expect(model.renamingTrack == nil, "Return in a header renames no track")

        model.transport(.playStop)
        await model.settleTransport()
        try #require(studio.playback != .stopped, "the play started")
        await pressReturn(at: text.headers[0].range.lowerBound, model, window, pane)
        let from = text.units[0].frames.lowerBound
        #expect(studio.playback != .stopped, "the play goes on")
        #expect(studio.playhead >= from && studio.playhead < from + 48_000, "paragraph 1")
        await model.close()
    }

    /// P21: Return with the insertion point in a unit does what it does in the lanes: Rename Track.
    @Test func returnInAUnitActsAsInTheLanes() async throws {
        let (model, studio, window, pane) = try await opened("unit")
        let unit = try secondUnit(pane)
        await seek(studio, to: 100_000)
        model.clickHeader("t1", flags: [])

        await pressReturn(at: unit.text.lowerBound, model, window, pane)

        #expect(model.renamingTrack == "t1")
        #expect(studio.playhead == 100_000, "no seek")
        await model.close()
    }
}
