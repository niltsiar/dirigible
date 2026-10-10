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

    /// The window point of the M or S box of header row `row`.
    func flagPoint(_ flag: TrackFlag, row: Int, in view: TimelineScrollView) throws -> NSPoint {
        try headerBoxPoint(flag == .muted ? 2 : 3, row: row, in: view)
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

        try clickPoint(try flagPoint(.muted, row: 0, in: view), in: window)

        #expect(flags(studio) == ["M-", "--"], "t1 is muted")
        await until("the session saves") { (try? Session(contentsOf: model.url))?.track("t1")?.isMuted == true }
        model.undo()
        #expect(flags(studio) == ["--", "--"] && !studio.canUndo, "one undo entry")
        await model.close()
    }

    /// The arm button: a click on the box of t2 arms t2, and a click on the on box of t1 disarms
    /// t1. Arm is window state: no mute, no solo, and no undo entry.
    @Test func aClickOnTheArmButtonArms() async throws {
        let (model, studio, window, view) = try await open()
        try #require(model.armed == ["t1"], "t1 arms at open; t2 has the same channel: \(model.armed)")

        try clickPoint(try headerBoxPoint(0, row: 1, in: view), in: window)
        #expect(model.armed == ["t1", "t2"], "a click arms t2: \(model.armed)")
        try clickPoint(try headerBoxPoint(0, row: 0, in: view), in: window)
        #expect(model.armed == ["t2"], "a click on an on button disarms t1: \(model.armed)")

        #expect(flags(studio) == ["--", "--"] && !studio.canUndo, "no mute, no solo, and no undo entry")
        await model.close()
    }

    /// During a take a click on R, M, or S changes nothing: the on boxes keep full opacity, but
    /// the buttons take no click. The click also does not go to the row, so the track selection
    /// stays.
    @Test func aClickDuringATakeChangesNothing() async throws {
        let (model, studio, window, view) = try await open()
        // The rows take a transport change at a later run-loop turn: each row reads `canEdit`.
        func setTransport(_ transport: Studio.Transport) async {
            let runs = model.headerRuns.rows
            studio.transport = transport
            await until("the rows take the transport") {
                drawNow(window)
                return model.headerRuns.rows > runs
            }
        }
        await setTransport(.recording(take: 1))
        try #require(!model.canEdit, "the take disables the buttons")

        model.timeline.selection = .none
        for box in [0, 2, 3] {
            try clickPoint(try headerBoxPoint(box, row: 1, in: view), in: window)
            try clickPoint(try headerBoxPoint(box, row: 1, in: view), in: window, flags: .shift)
        }

        #expect(model.armed == ["t1"] && flags(studio) == ["--", "--"], "no change: \(model.armed) \(flags(studio))")
        #expect(model.timeline.selection == .none, "the row did not get the click: \(model.timeline.selection)")
        // Control: a click on the row padding, left of the arm box, selects the track during a take.
        let arm = try headerBoxPoint(0, row: 1, in: view)
        try clickPoint(NSPoint(x: arm.x - 13, y: arm.y), in: window)
        #expect(model.timeline.selection != .none, "control: a click on the row selects")
        await setTransport(.idle)
        try clickPoint(try headerBoxPoint(0, row: 1, in: view), in: window)
        #expect(model.armed == ["t1", "t2"], "control: the same click arms t2 when idle")
        await model.close()
    }

    /// C7 b: a click on S adds a solo; solos add.
    @Test func aClickOnSAddsASolo() async throws {
        let (model, studio, window, view) = try await open()
        try clickPoint(try flagPoint(.soloed, row: 1, in: view), in: window)
        #expect(flags(studio) == ["--", "-S"])
        try clickPoint(try flagPoint(.soloed, row: 0, in: view), in: window)
        #expect(flags(studio) == ["-S", "-S"], "a second solo adds")
        try clickPoint(try flagPoint(.soloed, row: 1, in: view), in: window)
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

    /// Code gate 1 item 1: only a mouse click with Option sets every track. A key press or an AX
    /// press (no mouse event, or a key event with Option held) sets only its track.
    @Test func onlyAMouseClickWithOptionSetsEveryTrack() throws {
        func mouse(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let space = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        #expect(TrackToggles.isOptionClick(try mouse(.leftMouseUp, .option)), "an Option-click")
        #expect(TrackToggles.isOptionClick(try mouse(.leftMouseDown, .option)), "an Option mouse-down")
        #expect(!TrackToggles.isOptionClick(try mouse(.leftMouseUp, [])), "a plain click")
        #expect(!TrackToggles.isOptionClick(space), "Option-Space on a focused button")
        #expect(!TrackToggles.isOptionClick(nil), "an AX press with no event")
    }

    /// C7 e: with the name field focused, a click on M still acts.
    @Test func aClickOnMWithTheNameFocusedActs() async throws {
        let (model, studio, window, view) = try await open()
        let editor = try await focusName(in: window)
        editor.insertText("x", replacementRange: NSRange(location: 2, length: 0))
        try #require(model.drafts["t1"] == "T1x", "the typed name is a draft")

        try clickPoint(try flagPoint(.muted, row: 0, in: view), in: window)

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
        #expect(
            String(format: en["track.arm.label"] ?? "", "Host") == "Arm Host"
                && String(format: es["track.arm.label"] ?? "", "Host") == "Armar Host", "the arm label")
        #expect(
            en["track.arm.help"] == "Arm the track for recording."
                && es["track.arm.help"] == "Armar la pista para grabar.",
            "the arm help")
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
