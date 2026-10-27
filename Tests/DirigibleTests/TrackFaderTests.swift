import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// Track fader C7, C8, and C10 (F94): the fader of a header row, with no SwiftUI host. `NSCell`
/// tracks a drag in a modal loop that reads the event queue, so the tests call `beginDrag`, the
/// slider action, and `endDrag`, as `mouseDown` does (plan S5). The on-screen check covers the
/// real drag.
@Suite(.serialized) @MainActor struct TrackFaderTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    /// A 2-track model with 20 s of audio, so a play runs during a test.
    func model() async throws -> (SessionWindow, Studio) {
        try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20, audio: true), app: app)
    }

    /// The fader of `track` with the session gain, in a window, so an event has a target.
    func fader(_ model: SessionWindow, _ studio: Studio, track: TrackID = "t1") -> (NSWindow, TrackFaderView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let view = TrackFaderView()
        window.contentView?.addSubview(view)
        view.update(
            model: model, track: track, name: "T1", dB: studio.session.track(track)?.gain.dB ?? 0, enabled: true)
        return (window, view)
    }

    /// One drag step: the slider moves to `dB` on the scale of the drag start, and sends its action.
    func move(_ slider: FaderSlider, to dB: Double, start: Double = 0) {
        slider.doubleValue = FaderScale(start: start).position(dB: dB)
        slider.sendAction(slider.action, to: slider.target)
    }

    /// The gain of `track` in the mix of the running feed.
    func playedGain(_ studio: Studio, track: TrackID = "t1") async -> Double? {
        await studio.play.player?.session.track(track)?.gain.dB
    }

    func untilPlayed(_ studio: Studio, _ dB: Double, _ message: Comment) async {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(10)
        while await playedGain(studio) != dB {
            guard clock.now < end else {
                Issue.record(message)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Counts the autosaves of `studio`.
    func countSaves(_ studio: Studio) -> OSAllocatedUnfairLock<Int> {
        let saves = OSAllocatedUnfairLock(initialState: 0)
        let save = studio.environment.saveSession
        studio.environment.saveSession = { [saves] session, lock throws(SessionFileError) in
            saves.withLock { $0 += 1 }
            return try await save(session, lock)
        }
        return saves
    }

    /// A play with no sound: the offline output.
    func play(_ studio: Studio) async {
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        await untilPlayed(studio, 0, "the play feed runs")
    }

    @Test func aDragPreviewsThenMakesOneEdit() async throws {
        let (model, studio) = try await model()
        let saves = countSaves(studio)
        await play(studio)
        let (window, view) = fader(model, studio)
        let slider = view.slider
        let revision = studio.play.revision

        slider.beginDrag()
        for dB in [-1.0, -2, -3, -4.5, -6] { move(slider, to: dB) }

        await untilPlayed(studio, -6, "C7: the Player mixes the last drag value")
        #expect(studio.play.revision > revision, "C7: each preview has a new revision")
        #expect(!studio.canUndo, "C7: no edit during the drag")
        #expect(view.slider.shown == -6, "C7: the readout shows the drag value")
        slider.endDrag()

        #expect(studio.session.track("t1")?.gain.dB == -6, "C7: one edit at the mouse-up")
        try studio.undo()
        #expect(!studio.canUndo, "C7: one undo entry")
        #expect(studio.session.track("t1")?.gain == .zero, "C7: undo gives the old gain")
        await untilPlayed(studio, 0, "code gate 1: the undo reaches the Player after the drag")
        try studio.redo()
        try await Task.sleep(for: .milliseconds(600))
        #expect(saves.withLock { $0 } >= 1, "C7: an autosave after the edit")
        await studio.perform(.playStop)
        window.close()
        await model.close()
    }

    @Test func aDragBackToTheStartMakesNoEdit() async throws {
        let (model, studio) = try await model()
        await play(studio)
        let (window, view) = fader(model, studio)

        view.slider.beginDrag()
        move(view.slider, to: -6)
        await untilPlayed(studio, -6, "the preview reaches the Player")
        move(view.slider, to: 0.5)
        view.slider.endDrag()

        #expect(!studio.canUndo, "C7: a drag back to the start makes no edit")
        await untilPlayed(studio, 0, "C7: the Player gets the committed gain again")
        await studio.perform(.playStop)
        window.close()
        await model.close()
    }

    /// A mouse-down with a click count of 2 or with Option returns before the modal loop, so the
    /// test sends real events.
    @Test func aDoubleClickAndAnOptionClickResetToZero() async throws {
        let (model, studio) = try await model()
        try studio.edit(ripple: false) { session throws(SessionError) in try session.setGain(Gain(dB: -6)!, track: "t1")
        }
        let (window, view) = fader(model, studio)
        view.update(model: model, track: "t1", name: "T1", dB: -6, enabled: true)
        func click(count: Int, flags: NSEvent.ModifierFlags) throws {
            let point = view.slider.convert(NSPoint(x: view.slider.bounds.midX, y: view.slider.bounds.midY), to: nil)
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
            view.slider.mouseDown(with: event)
        }

        try click(count: 2, flags: [])
        #expect(studio.session.track("t1")?.gain == .zero, "C8: a double-click sets 0 dB")
        try studio.undo()
        #expect(studio.session.track("t1")?.gain.dB == -6, "C8: one edit")
        view.update(model: model, track: "t1", name: "T1", dB: -6, enabled: true)

        try click(count: 1, flags: .option)
        #expect(studio.session.track("t1")?.gain == .zero, "C8: an Option-click sets 0 dB")
        let edits = studio.sessionRevision
        view.update(model: model, track: "t1", name: "T1", dB: 0, enabled: true)
        try click(count: 2, flags: [])
        #expect(studio.sessionRevision == edits, "C8: a reset at 0 dB makes no edit")
        window.close()
        await model.close()
    }

    /// C8 (on-screen check): the first click of a real double-click off the thumb moves the thumb
    /// there and makes an edit. The reset takes its place: one undo gives the value before the
    /// double-click.
    /// The double-click off the thumb: the first click runs the drag path, and the thumb jumps to
    /// `jump`; the second click comes `delay` s after the first mouse-up.
    func doubleClick(
        _ view: TrackFaderView, _ window: NSWindow, from start: Double, jump: Double, delay: TimeInterval = 0,
        between: () throws -> Void = {}
    ) throws {
        view.slider.beginDrag()
        move(view.slider, to: jump, start: start)
        view.slider.endDrag()
        try between()
        let point = view.slider.convert(NSPoint(x: 10, y: view.slider.bounds.midY), to: nil)
        let second = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + delay, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        view.slider.mouseDown(with: second)
    }

    func setGain(_ studio: Studio, _ dB: Double, track: TrackID = "t1") throws {
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setGain(Gain(dB: dB)!, track: track)
        }
    }

    @Test func aDoubleClickOffTheThumbMakesOneEdit() async throws {
        let (model, studio) = try await model()
        try setGain(studio, -6)
        let (window, view) = fader(model, studio)

        try doubleClick(view, window, from: -6, jump: -36)

        #expect(studio.session.track("t1")?.gain == .zero, "C8: the double-click sets 0 dB")
        try studio.undo()
        #expect(studio.session.track("t1")?.gain.dB == -6, "C8: one undo gives the value before the double-click")
        window.close()
        await model.close()
    }

    /// Code gate 1 item 1: from 0 dB the double-click leaves no undo step and no redo step.
    @Test func aDoubleClickAtZeroLeavesNoStep() async throws {
        let (model, studio) = try await model()
        let (window, view) = fader(model, studio)

        try doubleClick(view, window, from: 0, jump: -36)

        #expect(studio.session.track("t1")?.gain == .zero, "C8: the double-click keeps 0 dB")
        #expect(!studio.canRedo, "C8: no redo step")
        #expect(!studio.canUndo, "C8: no undo step")
        window.close()
        await model.close()
    }

    /// Code gate 1 item 1: the reset joins the first click only when no other edit came between
    /// the clicks, and only within the double-click interval.
    @Test func aResetJoinsOnlyTheEditOfTheFirstClick() async throws {
        let (model, studio) = try await model()
        try setGain(studio, -6)
        let (window, view) = fader(model, studio)

        try doubleClick(view, window, from: -6, jump: -36) {
            try studio.edit(ripple: false) { session throws(SessionError) in try session.setMuted(true, tracks: ["t2"])
            }
        }
        #expect(studio.session.track("t2")?.isMuted == true, "code gate 1: the edit between the clicks stays")
        try studio.undo()
        #expect(studio.session.track("t1")?.gain.dB == -36, "code gate 1: the reset is an edit of its own")
        #expect(studio.session.track("t2")?.isMuted == true, "code gate 1: the undo keeps the edit between")

        try setGain(studio, -6)
        view.update(model: model, track: "t1", name: "T1", dB: -6, enabled: true)
        try doubleClick(view, window, from: -6, jump: -36, delay: NSEvent.doubleClickInterval + 1)
        try studio.undo()
        #expect(studio.session.track("t1")?.gain.dB == -36, "code gate 1: a late second click does not join")
        window.close()
        await model.close()
    }

    /// Code gate 1 item 2: a click on the thumb with no move keeps an off-grid gain, with no
    /// preview and no edit.
    @Test func aClickOnTheThumbKeepsAnOffGridGain() async throws {
        let (model, studio) = try await model()
        try setGain(studio, -6.25)
        let (window, view) = fader(model, studio)
        view.update(model: model, track: "t1", name: "T1", dB: -6.25, enabled: true)
        let revision = studio.sessionRevision

        view.slider.beginDrag()
        // Code gate 2: a click on the thumb can move the value by less than a point.
        view.slider.doubleValue += 0.4 / view.slider.bounds.width
        view.slider.sendAction(view.slider.action, to: view.slider.target)
        #expect(view.slider.shown == -6.25, "code gate 2: no rounded preview within half a point of the start")
        view.slider.endDrag()

        #expect(studio.session.track("t1")?.gain.dB == -6.25, "code gate 1: the gain stays")
        #expect(studio.sessionRevision == revision, "code gate 1: no edit")
        window.close()
        await model.close()
    }

    /// C10: the scroll wheel scrolls the view and never changes the gain.
    @Test func theScrollWheelGoesToTheNextResponder() async throws {
        let (model, studio) = try await model()
        let (window, view) = fader(model, studio)
        final class Catcher: NSResponder {
            var wheels = 0
            override func scrollWheel(with event: NSEvent) { wheels += 1 }
        }
        let catcher = Catcher()
        view.slider.nextResponder = catcher
        let wheel = try #require(
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 30, wheel2: 0, wheel3: 0)
                .flatMap(NSEvent.init(cgEvent:)))
        let before = view.slider.doubleValue

        view.slider.scrollWheel(with: wheel)

        #expect(catcher.wheels == 1, "C10: the wheel reaches the next responder")
        #expect(view.slider.doubleValue == before && !studio.canUndo, "C10: the wheel changes no gain")
        window.close()
        await model.close()
    }

    /// C10 (plan gate 2 item 2): the VoiceOver actions act on the fader track only, also with
    /// another track selected, and never beep.
    @Test func anAccessibilityIncrementMakesOneEdit() async throws {
        let (model, studio) = try await model()
        model.timeline.selection = .range(Marks(tracks: ["t2"]))
        let (window, view) = fader(model, studio)
        let start = studio.sessionRevision
        var beeps = 0
        model.beep = { beeps += 1 }

        #expect(view.slider.accessibilityPerformIncrement())
        #expect(studio.session.track("t1")?.gain.dB == 1, "C10: an increment adds 1 dB to the fader track")
        #expect(studio.session.track("t2")?.gain == .zero, "C10: the selected track keeps its gain")
        #expect(studio.sessionRevision == start + 1, "C10: one undo entry")
        view.update(model: model, track: "t1", name: "T1", dB: 1, enabled: true)
        #expect(view.slider.accessibilityPerformDecrement())
        #expect(studio.session.track("t1")?.gain == .zero, "C10: a decrement removes 1 dB")
        view.update(model: model, track: "t1", name: "T1", dB: 0, enabled: true)
        view.slider.setAccessibilityValue(NSNumber(value: FaderScale(start: 0).position(dB: -20)))
        #expect(studio.session.track("t1")?.gain.dB == -20, "C10: a set value sets the fader track")
        #expect(studio.sessionRevision == start + 3, "C10: one edit for each action")
        #expect(beeps == 0, "C10: no beep")
        window.close()
        await model.close()
    }

    /// Code gate 1 item 4: a disabled fader (a take) takes no VoiceOver action.
    @Test func aDisabledFaderTakesNoAccessibilityAction() async throws {
        let (model, studio) = try await model()
        let (window, view) = fader(model, studio)
        view.update(model: model, track: "t1", name: "T1", dB: 0, enabled: false)
        let revision = studio.sessionRevision

        #expect(!view.slider.accessibilityPerformIncrement(), "code gate 1: no increment")
        #expect(!view.slider.accessibilityPerformDecrement(), "code gate 1: no decrement")
        view.slider.setAccessibilityValue(NSNumber(value: FaderScale(start: 0).position(dB: -20)))

        #expect(studio.sessionRevision == revision, "code gate 1: a disabled fader changes nothing")
        window.close()
        await model.close()
    }

    /// C10: a slider action outside a drag (a key or an AX press) makes no edit and puts the thumb
    /// back on the session value.
    @Test func anActionOutsideADragMakesNoEdit() async throws {
        let (model, studio) = try await model()
        let (window, view) = fader(model, studio)
        #expect(view.slider.refusesFirstResponder, "C10: no key reaches the slider")

        move(view.slider, to: -10)

        #expect(!studio.canUndo, "C10: no edit")
        #expect(
            view.slider.doubleValue == FaderScale(start: 0).position(dB: 0), "C10: the thumb is on the session value")
        window.close()
        await model.close()
    }

    /// C10: the readout and the VoiceOver texts.
    @Test func theReadoutInEachLanguage() async throws {
        let (en, es) = (try stringsTable("en"), try stringsTable("es"))
        func text(_ dB: Double, _ table: [String: String], _ locale: String) -> String {
            TrackFaderView.readout(dB, locale: Locale(identifier: locale)) { table[$0.rawValue] ?? "" }
        }
        #expect(text(-6, en, "en") == "-6.0 dB")
        #expect(text(-6, es, "es") == "-6,0 dB")
        #expect(text(3.5, en, "en") == "+3.5 dB")
        #expect(text(0, en, "en") == "0.0 dB")
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for widest in [text(-96, en, "en"), text(-96, es, "es")] {
            // A label field has a margin of 2 pt at each side.
            let width = (widest as NSString).size(withAttributes: [.font: font]).width + 4
            #expect(width <= TrackFaderView.readoutWidth, "C10: \(widest) fits the readout: \(width)")
        }

        let (model, studio) = try await model()
        let (window, view) = fader(model, studio)
        view.update(model: model, track: "t1", name: "Host", dB: -6, enabled: true)
        #expect(
            view.slider.accessibilityLabel() == L10n.trackVolumeLabel.format("Host"), "C10: the label names the track")
        #expect(
            view.slider.accessibilityValueDescription() == view.readout.stringValue,
            "C10: the value is the readout text")
        window.close()
        await model.close()
    }
}
