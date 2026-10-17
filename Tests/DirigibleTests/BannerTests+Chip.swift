import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The record-over chip in the corner over the track headers (run timeline-clarity, L1-S2).
extension BannerTests {
    func popUps(under view: NSView?) -> [NSPopUpButton] {
        guard let view else { return [] }
        return ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap { popUps(under: $0) }
    }

    /// The alignment rect of `button` in window coordinates: the frame that the user sees.
    func shownFrame(_ button: NSPopUpButton) -> NSRect {
        button.convert(button.alignmentRect(forFrame: button.bounds), to: nil)
    }

    /// The pull-down button of the chip: the one pop-up button in the band of the time ruler. The
    /// route menus of the headers are below that band.
    func chipButton(_ window: NSWindow, _ view: TimelineScrollView) -> NSPopUpButton? {
        window.contentView?.layoutSubtreeIfNeeded()
        let band = view.ruler.convert(view.ruler.bounds, to: nil)
        return popUps(under: window.contentView).first {
            let frame = shownFrame($0)
            return frame.minY >= band.minY && frame.maxY <= band.maxY
        }
    }

    /// The window with 20 tracks of 20 s, the last track armed, and the playhead at 100000: the
    /// lane of the last track is under the view, so the chip shows.
    func chipWindow() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let (model, studio, window, _) = try await open(tracks: TimelineViewTests.tracksThatDoNotFit, seconds: 20)
        await until("the window shows the lanes") { model.timelineView?.window != nil }
        let view = try #require(model.timelineView)
        view.viewWillMove(toWindow: nil)
        model.armed = [TrackID("t\(TimelineViewTests.tracksThatDoNotFit)")]
        await studio.perform(.seek(.frame(100_000)))
        await until(limit: .seconds(10), "the chip body shows the warning") {
            window.contentView?.layoutSubtreeIfNeeded()
            return !model.shown.recordOver.isEmpty && model.overlayShows > 0
        }
        return (model, studio, window, view)
    }

    /// C1, C12: the chip is a button in the band of the time ruler, inside the header column, so it
    /// covers no ruler time. It follows a change of the header width with no tick.
    @Test func theRecordOverChipStaysInTheHeaderCorner() async throws {
        let (model, _, window, view) = try await chipWindow()
        var found: NSPopUpButton?
        await until(limit: .seconds(10), "the chip button shows") {
            found = chipButton(window, view)
            return found != nil
        }
        let chip = try #require(found)
        for step in [0.0, -160, 40, 200] {
            if step != 0 { view.headers.step(by: step) }
            let width = view.headers.width.points
            await until(limit: .seconds(10), "the chip takes the header width \(width)") {
                window.contentView?.layoutSubtreeIfNeeded()
                return abs(shownFrame(chip).width - (width - 2 * RecordOverChip.inset)) < 1.5
            }
            let frame = shownFrame(chip)
            let headers = view.headers.convert(view.headers.bounds, to: nil)
            #expect(frame.minX >= headers.minX && frame.maxX <= headers.maxX, "chip \(frame), headers \(headers)")
        }
        await model.close()
    }

    /// C2: at the narrowest header (180 pt) the title of the real chip button holds the chip text of
    /// each language on one line, with the font and the room that the button gives it.
    @Test func theRecordOverChipFitsTheNarrowestHeaderInEachLanguage() async throws {
        let (model, _, window, view) = try await chipWindow()
        var found: NSPopUpButton?
        await until(limit: .seconds(10), "the chip button shows") {
            found = chipButton(window, view)
            return found != nil
        }
        let chip = try #require(found)
        view.headers.step(by: HeaderWidth(0).points - view.headers.width.points)
        await until(limit: .seconds(10), "the chip takes the narrowest header") {
            window.contentView?.layoutSubtreeIfNeeded()
            return abs(shownFrame(chip).width - (HeaderWidth(0).points - 2 * RecordOverChip.inset)) < 1.5
        }
        let title = try #require(titleField(chip), "the chip button has a title field")
        let font = try #require(title.font)
        for language in AppLanguage.allCases.map(\.rawValue) {
            let text = try #require(try stringsTable(language)[L10n.recordOverChip.rawValue])
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.sizeToFit()
            #expect(
                label.frame.width <= title.frame.width,
                "\(language): \(text) needs \(label.frame.width) of \(title.frame.width) pt")
        }
        await model.close()
    }

    /// The text field that shows the title of a pop-up button.
    func titleField(_ view: NSView) -> NSTextField? {
        (view as? NSTextField) ?? view.subviews.lazy.compactMap { titleField($0) }.first
    }

    /// The chip and the header corner have one width: the window owns it. A pane that SwiftUI builds
    /// again (all tracks deleted, then Undo) takes the width of the window, not a stored value.
    @Test func aRebuiltPaneKeepsTheHeaderWidthOfTheWindow() async throws {
        let (model, studio, _, _) = try await open(tracks: 2, seconds: 10)
        await until("the window shows the lanes") { model.timelineView?.window != nil }
        let first = try #require(model.timelineView)
        first.headers.step(by: -160)
        try #require(model.headerWidth == HeaderWidth(180), "the drag sets the width of the window")

        let tracks = studio.session.tracks.map(\.id)
        try studio.edit(ripple: false) { s throws(SessionError) in
            for track in tracks { try s.removeTrack(track) }
        }
        await until(limit: .seconds(10), "the empty state replaces the pane") { model.timelineView?.window == nil }
        try studio.undo()
        var second: TimelineScrollView?
        await until(limit: .seconds(10), "a new pane shows the lanes") {
            second = model.timelineView.flatMap { $0 !== first && $0.window != nil ? $0 : nil }
            return second != nil
        }
        let rebuilt = try #require(second)
        #expect(
            rebuilt.headers.width == model.headerWidth, "pane \(rebuilt.headers.width), window \(model.headerWidth)")
        await model.close()
    }

    /// C3: Go to End moves the playhead past every clip, so the warning goes.
    @Test func goToEndFromTheChipHidesIt() async throws {
        let (model, studio, _, _) = try await chipWindow()
        let end = studio.session.end
        try #require(studio.playhead < end)

        model.recordOver(.goToEnd)

        await until(limit: .seconds(10), "the playhead goes to the end and the warning goes") {
            studio.playhead == end && model.shown.recordOver.isEmpty
        }
        #expect(studio.playhead == end && model.shown.recordOver.isEmpty)
        await model.close()
    }

    /// C3: Show Clip puts the frame that Record reaches and the whole lane in view, with the view
    /// zoomed in and scrolled away from both.
    @Test func showClipBringsTheReachedClipIntoView() async throws {
        let (model, _, window, view) = try await chipWindow()
        for _ in 0..<3 { model.run(.zoomIn) }
        view.scroll(toFrame: 800_000)
        let last = TimelineViewTests.tracksThatDoNotFit - 1
        let visible = try #require(model.timeline.visible)
        try #require(!visible.frames.contains(100_000) && !visible.lanes.contains(last), "\(visible)")

        model.recordOver(.showClip)

        await until(limit: .seconds(10), "the warning goes") {
            window.contentView?.layoutSubtreeIfNeeded()
            return model.shown.recordOver.isEmpty
        }
        let laneHeight = try #require(view.lanes.inputs?.laneHeight)
        let shown = view.shown
        #expect(model.timeline.visible?.frames.contains(100_000) == true, "the frame is in view")
        #expect(
            shown.minY <= Double(last) * laneHeight && shown.maxY >= Double(last + 1) * laneHeight,
            "the whole lane is in view: \(shown)")
        await model.close()
    }

    /// C3: Turn Off Record disarms the track of its item and no other track.
    @Test func turnOffRecordDisarmsOnlyThatTrack() async throws {
        let (model, _, _, view) = try await chipWindow()
        let (first, last) = (TrackID("t1"), TrackID("t\(TimelineViewTests.tracksThatDoNotFit)"))
        let insets = view.contentView.contentInsets
        view.contentView.scroll(to: NSPoint(x: view.contentView.bounds.minX, y: 100 - insets.top))
        view.reflectScrolledClipView(view.contentView)
        model.armed = [first, last]
        await until(limit: .seconds(10), "both armed tracks are in the warning") {
            model.shown.recordOver.reached.map(\.track) == [first, last]
        }

        model.recordOver(.turnOffRecord(last))

        #expect(model.armed == [first], "only the first track stays armed")
        await until(limit: .seconds(10), "the warning names the first track") {
            model.shown.recordOver.reached.map(\.track) == [first]
        }
        await model.close()
    }

    /// C3: each item first saves the typed name of a track, as a ruler press does.
    @Test(arguments: [RecordOverAction.goToEnd, .showClip, .turnOffRecord("t20")])
    func aChipItemSavesTheTypedTrackName(_ action: RecordOverAction) async throws {
        let (model, studio, _, _) = try await chipWindow()
        model.drafts["t20"] = "Typed"

        model.recordOver(action)

        #expect(studio.session.track("t20")?.name == "Typed", "\(action)")
        #expect(model.drafts["t20"] == nil)
        await model.close()
    }

    /// C11: a play with the chip shown writes no record-over state per chrome turn. The detail
    /// text holds the clip start, not the playhead, so the chip body runs no more.
    @Test func aPlayWithTheChipShownWritesNoRecordOverStatePerTurn() async throws {
        let (model, studio, window, _) = try await chipWindow()
        let chrome = try #require(model.chrome)
        let playhead = studio.playhead

        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 9_600)
        await until(limit: .seconds(10), "the play moves") { studio.playhead > playhead }
        // The start of the play writes the shown chrome once. A turn after it writes no record-over state.
        chrome.update()
        window.contentView?.layoutSubtreeIfNeeded()
        let (shows, turns) = (model.overlayShows, chrome.turns)
        for _ in 0..<10 {
            _ = await studio.renderOffline(frames: 24_000)
            try await Task.sleep(for: .milliseconds(50))
            chrome.update()
            window.contentView?.layoutSubtreeIfNeeded()
        }

        #expect(chrome.turns >= turns + 10, "ten chrome turns ran")
        #expect(studio.playback != .stopped && studio.playhead > playhead, "the play goes on")
        #expect(!model.shown.recordOver.isEmpty, "the chip stayed")
        #expect(model.overlayShows == shows, "the chip body ran \(model.overlayShows - shows) times")
        await studio.perform(.playStop)
        await model.close()
    }
}
