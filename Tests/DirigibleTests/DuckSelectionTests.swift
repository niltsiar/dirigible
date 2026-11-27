import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Edit > Duck Selection (Shift-D, decision 0060): the range gain at the duck depth with the ramps of
/// the range gain. Tracks t1, t2, and t3 have a clip c1, c2, and c3 of 10 s (480 000 frames at 48 kHz)
/// with no envelope. The ramp is 500 ms, 24 000 frames.
@Suite(.serialized) @MainActor struct DuckSelectionTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    static let range: Range<Frames> = 48_000..<96_000

    /// The envelope of a clip of the range `range` after one press, at 0 and -16 dB.
    static let dip = [(24_000, 0.0), (48_000, -16), (95_999, -16), (119_999, 0)].map { point($0.0, $0.1) }

    static func point(_ frame: Int, _ dB: Double) -> GainEnvelope.Point {
        GainEnvelope.Point(frame: Frames(frame), gain: Gain(dB: dB)!)
    }

    func open() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        try await openLanes(app, try await timelinePackage(in: folder.url, tracks: 3, seconds: 10))
    }

    func select(_ model: SessionWindow, tracks: Set<TrackID> = ["t1", "t2"], range: Range<Frames> = range) {
        model.timeline.selection = .range(Marks(inPoint: range.lowerBound, outPoint: range.upperBound, tracks: tracks))
    }

    /// A Shift-D key-down through the item, as the menu sends it.
    func press(_ window: NSWindow, repeats: Bool = false) {
        app.timeline(.duckSelection, event: key(.keyDown, "D", code: 2, repeat: repeats, in: window), in: window)
    }

    func beeps(_ model: SessionWindow) -> () -> Int {
        var count = 0
        model.beep = { count += 1 }
        return { count }
    }

    func envelope(_ session: Session, _ clip: ClipID = "c1") -> GainEnvelope? { session.clip(clip)?.clip.envelope }

    /// The gain of c1 at the first and the last frame of the range.
    func levels(_ session: Session) -> [Double] {
        [48_000, 95_999].map { envelope(session)?.gain(at: Frames($0)) ?? .nan }
    }

    @Test func shiftDDucksTheSelectedRange() async throws {
        let (model, studio, window, view) = try await open()
        #expect(window.makeFirstResponder(view.lanes))
        select(model)
        var expected = studio.session

        press(window)

        try expected.changeGain(by: Gain(dB: -16)!, in: Self.range, on: ["t1", "t2"], ramp: 24_000)
        #expect(studio.session == expected, "the range gain of decision 0060 at -16 dB")
        for clip in ["c1", "c2"] { #expect(envelope(studio.session, ClipID(clip))?.points == Self.dip, "\(clip)") }
        #expect(envelope(studio.session, "c3")?.isEmpty == true, "t3 is not selected")
        let c1 = try #require(envelope(studio.session))
        #expect(c1.gain(at: 36_000) == -8, "half way down the ramp")
        #expect(c1.gain(at: 23_999) == 0, "no ramp inside the range")
        #expect(c1.gain(at: 47_999) < 0 && c1.gain(at: 47_999) > -16, "the ramp ends at the range")
        await model.close()
    }

    @Test func shiftDIsOneUndoStep() async throws {
        let (model, studio, window, view) = try await open()
        #expect(window.makeFirstResponder(view.lanes))
        select(model)
        try #require(!studio.canUndo)
        let (before, selection) = (studio.session, model.timeline.selection)

        press(window)

        let after = studio.session
        #expect(after != before && model.timeline.selection == selection, "the press keeps the selection")
        try studio.undo()
        #expect(studio.session == before && !studio.canUndo, "one undo entry")
        try studio.redo()
        #expect(studio.session == after)
        await model.close()
    }

    /// The sixth press reaches -96 dB. The seventh computes -112 dB, which clamps to -96 dB: no change,
    /// no undo entry, and a beep.
    @Test func repeatedShiftDStacksToTheFloor() async throws {
        let (model, studio, window, view) = try await open()
        #expect(window.makeFirstResponder(view.lanes))
        select(model)
        let beeps = beeps(model)
        var sessions: [Session] = []
        for _ in 1...6 {
            press(window)
            sessions.append(studio.session)
        }
        #expect(levels(sessions[1]) == [-32, -32], "press 2 lowers the range again")
        #expect(levels(sessions[5]) == [-96, -96], "press 6 reaches the floor")
        #expect(beeps() == 0)

        press(window)

        #expect(studio.session == sessions[5] && beeps() == 1, "press 7 beeps and changes nothing")
        try studio.undo()
        #expect(studio.session == sessions[4], "press 7 left no undo entry: \(levels(studio.session))")
        await model.close()
    }

    /// With the name field focused, the item gives the key to the field, in two runs: with a range, and
    /// with no range (an item that is off with no range takes the key and types nothing).
    @Test(arguments: [true, false])
    func shiftDTypesInAFocusedName(withRange: Bool) async throws {
        let (model, studio, window, _) = try await open()
        if withRange { select(model, tracks: ["t1"]) } else { model.timeline.selection = .none }
        let editor = try await focusName(in: window)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        let before = studio.session
        let count = beeps(model)

        press(window)

        #expect(editor.string == "T1D", "the field typed the letter: \(editor.string)")
        #expect(studio.session == before && count() == 0)
        await model.close()
    }

    /// Three cases beep and change nothing. Control: a range in silence whose ramp reaches c1 changes it.
    @Test func shiftDWithNothingToDuckBeeps() async throws {
        let (model, studio, window, view) = try await open()
        #expect(window.makeFirstResponder(view.lanes))
        let before = studio.session
        let count = beeps(model)

        model.timeline.selection = .none
        press(window)
        model.timeline.selection = .clips(try #require(ClipSet(["c1"])))
        press(window)
        select(model, tracks: ["t1"], range: 528_000..<576_000)
        press(window)

        #expect(studio.session == before && !studio.canUndo && count() == 3, "three beeps and no change: \(count())")
        select(model, tracks: ["t1"], range: 480_000..<528_000)
        press(window)
        #expect(envelope(studio.session)?.points == [Self.point(456_000, 0), Self.point(480_000, -16)])
        #expect(count() == 3, "the ramp reaches c1: a change, no beep")
        await model.close()
    }

    /// A key window that is no session window gets the key, with a range and with no range.
    @Test(arguments: [true, false])
    func shiftDInAPanelTypesThere(withRange: Bool) async throws {
        let (model, studio, _, _) = try await open()
        if withRange { select(model, tracks: ["t1"]) } else { model.timeline.selection = .none }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered,
            defer: false)
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        panel.contentView?.addSubview(field)
        #expect(panel.makeFirstResponder(field))
        let before = studio.session
        let count = beeps(model)

        app.timeline(.duckSelection, event: key(.keyDown, "D", code: 2, in: panel), in: panel)

        #expect(field.stringValue == "D" && studio.session == before && count() == 0, "\(field.stringValue)")
        await model.close()
    }

    /// Rule K1: a plain key is never off, so a focused field gets it. With no key session window too.
    @Test func theItemIsNeverOff() async throws {
        let (model, _, _, _) = try await open()
        model.timeline.selection = .none
        #expect(model.isOn(.duckSelection), "no range")
        model.timeline.selection = .clips(try #require(ClipSet(["c1"])))
        #expect(model.isOn(.duckSelection), "a clip set")
        select(model, tracks: ["t1"], range: 528_000..<576_000)
        #expect(model.isOn(.duckSelection), "a range whose ramps reach no clip")
        select(model, tracks: ["t1"])
        #expect(model.isOn(.duckSelection), "a range on t1")
        app.key = nil
        #expect(app.isOn(.duckSelection), "no key session window")
        await model.close()
    }
}

/// Decision 0060: Duck Selection does nothing during a take, in every selection state, and the take goes on.
extension EditTakeTests {
    @Test func duckSelectionDoesNothingDuringATake() async throws {
        let model = await app.open(try await package())
        let studio = try #require(await model.opened() ? model.studio : nil)
        studio.environment = hal.environment
        model.timeline.marks = Marks(inPoint: 96_000, outPoint: 192_000, tracks: ["t1"])
        let selections: [Selection] = [
            model.timeline.selection, .none, .clips(try #require(ClipSet(["c1"]))),
        ]
        await model.record()
        try #require(studio.transport == .recording(take: 1))
        await hal.feed(seconds: 0.2)
        var beeps = 0
        model.beep = { beeps += 1 }
        let (before, undo) = (studio.session, studio.canUndo)

        for selection in selections {
            model.timeline.selection = selection
            model.run(.duckSelection)
        }

        #expect(studio.session == before && studio.canUndo == undo, "no envelope changed")
        #expect(studio.session.clip("c1")?.clip.envelope.isEmpty == true && beeps == 0 && model.alert == nil)
        #expect(studio.transport == .recording(take: 1), "the take goes on")
        await hal.feed(seconds: 0.2)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }
}
