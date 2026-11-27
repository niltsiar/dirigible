import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Duck Selection on a held key and for VoiceOver (decision 0060). The test runner has no string table,
/// so each announced text is the key of its L10n case, whatever its total. The tests check the text
/// against `L10n.duckSelectionDone.format` with the expected total, and check the total itself on the
/// gain that `PointGain` reads at the frame of the announcement. `LocalizationTests` checks that each
/// table has the key and the same specifiers as English.
extension DuckSelectionTests {
    /// The text of an announcement with a total of `dB`, as `announceGainPoint` builds it.
    func said(_ dB: Double) -> String {
        L10n.duckSelectionDone.format(
            ReadoutLayer.decibels(dB, locale: .current) + " " + L10n.inspectorDecibels.text)
    }

    /// The gain that the Gain at playhead field shows at `frame`, for the selection of `model`.
    func gain(_ model: SessionWindow, _ studio: Studio, at frame: Frames) -> ClipInspection.Shown<Double>? {
        PointGain(at: frame, selection: model.timeline.selection, session: studio.session)?.gain
    }

    /// A held Shift-D is one press. A key-down that is no repeat ducks again.
    @Test func aHeldShiftDDucksOnce() async throws {
        let (model, studio, window, view) = try await open()
        #expect(window.makeFirstResponder(view.lanes))
        select(model)
        let beeps = beeps(model)
        let before = studio.session

        press(window)
        let once = studio.session
        press(window, repeats: true)

        #expect(studio.session == once && levels(once) == [-16, -16] && beeps() == 0, "a repeat changed the session")
        press(window)
        #expect(levels(studio.session) == [-32, -32], "a later key-down ducks again")
        try studio.undo()
        #expect(studio.session == once, "one undo entry for the second press")
        try studio.undo()
        #expect(studio.session == before && !studio.canUndo, "the repeat added no undo entry")
        await model.close()
    }

    /// The repeat guard sits after the forward of the key, so a held key in a field still types.
    @Test func aHeldShiftDTypesInAFocusedName() async throws {
        let (model, studio, window, _) = try await open()
        select(model, tracks: ["t1"])
        let editor = try await focusName(in: window)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        let before = studio.session

        press(window, repeats: true)

        #expect(editor.string == "T1D" && studio.session == before, "\(editor.string)")
        await model.close()
    }

    /// Press 1 and press 2 each say the total at the first frame of the range, at medium priority. The
    /// totals differ by state: -16 dB, then -32 dB.
    @Test func shiftDAnnouncesTheNewTotal() async throws {
        let (model, studio, window, view) = try await open()
        #expect(window.makeFirstResponder(view.lanes))
        select(model)
        var heard: [(String, NSAccessibilityPriorityLevel)] = []
        model.chrome?.announce = { text, priority in heard.append((text, priority)) }

        press(window)
        #expect(gain(model, studio, at: 48_000) == .value(-16) && heard.count == 1, "press 1: \(heard)")
        press(window)
        #expect(gain(model, studio, at: 48_000) == .value(-32) && heard.count == 2, "press 2: \(heard)")

        #expect(heard.map(\.0) == [said(-16), said(-32)], "\(heard)")
        #expect(heard.map(\.1) == [.medium, .medium])
        await model.close()
    }

    /// c1 starts at 72 000, so the range 48 000..<96 000 starts in a gap. `PointGain` is nil at the start
    /// of the range, so a read there says nothing. The read frame is the first frame that c1 plays.
    @Test func shiftDFromAGapAnnouncesTheTotal() async throws {
        let (model, studio, window, view) = try await open()
        #expect(window.makeFirstResponder(view.lanes))
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.move("c1", to: "t1", start: 72_000)
        }
        select(model, tracks: ["t1"])
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }

        press(window)

        #expect(gain(model, studio, at: 48_000) == nil, "the range starts in a gap")
        #expect(gain(model, studio, at: 72_000) == .value(-16), "c1 plays 72 000 at -16 dB")
        #expect(heard == [said(-16)], "\(heard)")
        await model.close()
    }

    /// t1 ducked alone first: at the start of the range t1 is at -32 dB and t2 at -16 dB.
    @Test func shiftDOnTracksOfDifferentTotalsAnnouncesMixed() async throws {
        let (model, studio, window, view) = try await open()
        #expect(window.makeFirstResponder(view.lanes))
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }

        select(model, tracks: ["t1"])
        press(window)
        select(model)
        press(window)

        #expect(gain(model, studio, at: 48_000) == .mixed, "t1 at -32 dB, t2 at -16 dB")
        #expect(heard == [said(-16), L10n.duckSelectionDone.format(L10n.inspectorMixed.text)], "\(heard)")
        await model.close()
    }

    /// A beep says nothing: no selection, a clip set, ramps that reach no clip, and the floor. A range in
    /// silence whose ramp reaches c2 changes c2, but no selected clip plays a frame of the range.
    @Test func aDuckThatChangesNothingAnnouncesNothing() async throws {
        let (model, studio, window, view) = try await open()
        #expect(window.makeFirstResponder(view.lanes))
        let beeps = beeps(model)
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }

        model.timeline.selection = .none
        press(window)
        model.timeline.selection = .clips(try #require(ClipSet(["c1"])))
        press(window)
        select(model, tracks: ["t1"], range: 528_000..<576_000)
        press(window)
        #expect(heard.isEmpty && beeps() == 3, "\(heard) \(beeps())")

        select(model, tracks: ["t1"])
        for _ in 1...6 { press(window) }
        heard.removeAll()
        press(window)
        #expect(heard.isEmpty && beeps() == 4, "press 7 at the floor: \(heard) \(beeps())")

        let revision = studio.sessionRevision
        select(model, tracks: ["t2"], range: 480_000..<528_000)
        press(window)
        #expect(studio.sessionRevision == revision + 1 && beeps() == 4, "the ramp reached c2")
        #expect(heard.isEmpty, "no selected clip plays a frame of the range: \(heard)")
        await model.close()
    }
}
