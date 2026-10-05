import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Mute and solo C7 and C8 (decision 0039): the M and S buttons of the track headers, and the
/// Track > Mute Track and Solo Track keys. The clicks go to the hit view of the frame view, as
/// `NSWindow.sendEvent` sends them in a key window.
@Suite(.serialized) @MainActor struct TrackMuteSoloWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    func open() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        try await openLanes(app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 20))
    }

    /// The window point of the M or S box of header row `row`. The boxes are SwiftUI shapes: the
    /// hit views of 18 x 16 pt in the header, top row first, M left of S.
    func flagPoint(_ flag: TrackFlag, row: Int, in view: TimelineScrollView) throws -> NSPoint {
        let window = try #require(view.window)
        window.contentView?.layoutSubtreeIfNeeded()
        drawNow(window)
        func boxes(_ view: NSView) -> [NSRect] {
            let frame = view.convert(view.bounds, to: nil)
            let box =
                String(describing: type(of: view)).contains("ShapeHitTesting")
                && frame.size == NSSize(width: 18, height: 16)
            return (box ? [frame] : []) + view.subviews.flatMap(boxes)
        }
        let frames = boxes(view.headers.host).sorted { ($0.midY, -$0.minX) > ($1.midY, -$1.minX) }
        try #require(frames.count > 2 * row + 1, "M and S in row \(row): \(frames)")
        let frame = frames[2 * row + (flag == .muted ? 0 : 1)]
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    func click(_ point: NSPoint, in window: NSWindow) throws {
        drawNow(window)
        let hit = try #require(window.contentView?.superview?.hitTest(point))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { hit.mouseDown(with: event) } else { hit.mouseUp(with: event) }
        }
        drawNow(window)
    }

    func flags(_ studio: Studio) -> [String] {
        studio.session.tracks.map { ($0.isMuted ? "M" : "-") + ($0.isSoloed ? "S" : "-") }
    }

    /// C7 a: a click on M of t1, with the lanes as first responder, mutes t1 in one undo entry, and
    /// the session saves. Undo clears it.
    @Test func aClickOnMMutesInOneUndoEntry() async throws {
        let (model, studio, window, view) = try await open()
        #expect(window.makeFirstResponder(view.lanes))
        try #require(!studio.canUndo)

        try click(try flagPoint(.muted, row: 0, in: view), in: window)

        #expect(flags(studio) == ["M-", "--"], "t1 is muted")
        await until("the session saves") { (try? Session(contentsOf: model.url))?.track("t1")?.isMuted == true }
        model.undo()
        #expect(flags(studio) == ["--", "--"] && !studio.canUndo, "one undo entry")
        await model.close()
    }

    /// C7 b: a click on S adds a solo; solos add.
    @Test func aClickOnSAddsASolo() async throws {
        let (model, studio, window, view) = try await open()
        try click(try flagPoint(.soloed, row: 1, in: view), in: window)
        #expect(flags(studio) == ["--", "-S"])
        try click(try flagPoint(.soloed, row: 0, in: view), in: window)
        #expect(flags(studio) == ["-S", "-S"], "a second solo adds")
        try click(try flagPoint(.soloed, row: 1, in: view), in: window)
        #expect(flags(studio) == ["-S", "--"], "a click on an on button turns it off")
        await model.close()
    }

    /// C7 c: Option-click sets every track to the new state, one undo entry each. The view gives
    /// `all` from the modifier flags of the click; the on-screen check covers that part.
    @Test func optionClickSetsEveryTrack() async throws {
        let (model, studio, _, _) = try await open()
        model.setFlag(.muted, true, track: "t1", all: true)
        #expect(flags(studio) == ["M-", "M-"], "every track is muted")
        model.setFlag(.muted, false, track: "t1", all: true)
        #expect(flags(studio) == ["--", "--"], "every track is unmuted")
        model.undo()
        #expect(flags(studio) == ["M-", "M-"], "one undo entry for the unmute")
        await model.close()
    }

    /// C7 e: with the name field focused, a click on M still acts.
    @Test func aClickOnMWithTheNameFocusedActs() async throws {
        let (model, studio, window, view) = try await open()
        let editor = try await focusName(in: window)
        editor.insertText("x", replacementRange: NSRange(location: 2, length: 0))
        try #require(model.drafts["t1"] == "T1x", "the typed name is a draft")

        try click(try flagPoint(.muted, row: 0, in: view), in: window)

        #expect(flags(studio) == ["M-", "--"], "the click acts with the name focused")
        #expect(
            window.firstResponder === editor && model.drafts["t1"] == "T1x",
            "U22: the field keeps the focus and the draft")
        await model.close()
    }

    /// C7 f: the VoiceOver label names the track, and the help tag gives the key and the
    /// Option-click, in English and in Spanish. The on-screen AX check reads them in the app.
    @Test func theButtonsNameTheTrackAndGiveTheState() throws {
        let (en, es) = (try stringsTable("en"), try stringsTable("es"))
        func format(_ table: [String: String], _ key: L10n, _ name: String) -> String {
            String(format: table[key.rawValue] ?? "", name)
        }
        #expect(
            format(en, .trackMuteLabel, "Host") == "Mute Host" && format(en, .trackSoloLabel, "Host") == "Solo Host")
        #expect(
            format(es, .trackMuteLabel, "Host") == "Silenciar Host"
                && format(es, .trackSoloLabel, "Host") == "Solo Host")
        #expect(TrackFlag.muted.label("Host") == L10n.trackMuteLabel.format("Host"), "the mute label key")
        #expect(TrackFlag.soloed.label("Host") == L10n.trackSoloLabel.format("Host"), "the solo label key")
        for table in [en, es] {
            #expect(
                table["track.mute.help"]?.contains("(⇧M)") == true && table["track.solo.help"]?.contains("(⇧S)") == true
            )
        }
    }

    /// C8 a: with the lanes as first responder and a range on t1 and t2, Shift-M mutes both when one
    /// is unmuted, and unmutes both when both are muted.
    @Test func shiftMMutesTheSelectedTracks() async throws {
        let (model, studio, window, view) = try await open()
        #expect(window.makeFirstResponder(view.lanes))
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1", "t2"])
        model.setFlag(.muted, true, track: "t2", all: false)
        let shiftM = key(.keyDown, "M", code: 46, in: window)

        app.timeline(.muteTracks, event: shiftM, in: window)
        #expect(flags(studio) == ["M-", "M-"], "one unmuted track: both mute")
        app.timeline(.muteTracks, event: shiftM, in: window)
        #expect(flags(studio) == ["--", "--"], "both muted: both unmute")
        app.timeline(.soloTracks, event: key(.keyDown, "S", code: 1, in: window), in: window)
        #expect(flags(studio) == ["-S", "-S"], "Shift-S solos both")
        await model.close()
    }

    /// C8 b: with no selection, or a clip set, the items beep and change nothing (decision 0038).
    @Test func shiftMWithNoTrackBeeps() async throws {
        let (model, studio, window, view) = try await open()
        #expect(window.makeFirstResponder(view.lanes))
        var beeps = 0
        model.beep = { beeps += 1 }
        let before = studio.session

        model.timeline.selection = .none
        app.timeline(.muteTracks, event: key(.keyDown, "M", code: 46, in: window), in: window)
        let clips = try #require(ClipSet(["c1"]))
        model.timeline.selection = .clips(clips)
        app.timeline(.soloTracks, event: key(.keyDown, "S", code: 1, in: window), in: window)

        #expect(studio.session == before && beeps == 2, "two beeps and no change: \(beeps)")
        await model.close()
    }

    /// C8 c: with the name field focused, Shift-M types "M" in the field and the session stays.
    @Test func shiftMTypesInAFocusedName() async throws {
        let (model, studio, window, _) = try await open()
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        let editor = try await focusName(in: window)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        let before = studio.session

        app.timeline(.muteTracks, event: key(.keyDown, "M", code: 46, in: window), in: window)
        app.timeline(.soloTracks, event: key(.keyDown, "S", code: 1, in: window), in: window)

        #expect(editor.string == "T1MS", "the field typed the letters: \(editor.string)")
        #expect(studio.session == before)
        await model.close()
    }
}
