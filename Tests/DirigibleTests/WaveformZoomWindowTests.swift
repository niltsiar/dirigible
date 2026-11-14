import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The waveform zoom of a session window: Waveform Zoom In and Out step the seven ranges, the range
/// is window state, and Reset goes to the app default. 2 tracks of 20 s with a file on disk.
@Suite(.serialized) @MainActor struct WaveformZoomWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func open() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let lanes = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 20, audio: true))
        lanes.3.viewWillMove(toWindow: nil)
        return lanes
    }

    /// Waits until the lanes of `view` have the inputs of `range`.
    func shows(_ range: WaveformRange, _ view: TimelineScrollView, _ window: NSWindow) async -> Bool {
        await until(limit: .seconds(10), "the lanes draw at \(range.rawValue) dB") {
            window.contentView?.layoutSubtreeIfNeeded()
            return view.lanes.inputs?.range == range
        }
        return view.lanes.inputs?.range == range
    }

    /// Zoom In steps 60, 72, 84, 96 and is off at 96 dB; Zoom Out steps 96 down to 24 and is off at 24
    /// dB. A step at the end beeps and keeps the range.
    @Test func theKeysStepTheRange() async throws {
        let (model, _, window, view) = try await open()
        var beeps = 0
        model.beep = { beeps += 1 }
        #expect(model.timeline.waveformRange == .db60, "a new window opens at the factory default")

        for expected in [WaveformRange.db72, .db84, .db96] {
            model.run(.waveformZoomIn)
            #expect(model.timeline.waveformRange == expected)
            #expect(await shows(expected, view, window), "Zoom In to \(expected.rawValue) dB")
        }
        #expect(!model.isOn(.waveformZoomIn), "Zoom In is off at 96 dB")
        model.run(.waveformZoomIn)
        #expect(model.timeline.waveformRange == .db96 && beeps == 1, "a step past 96 dB beeps and keeps 96 dB")

        for expected in [WaveformRange.db84, .db72, .db60, .db48, .db36, .db24] {
            model.run(.waveformZoomOut)
            #expect(model.timeline.waveformRange == expected)
            #expect(await shows(expected, view, window), "Zoom Out to \(expected.rawValue) dB")
        }
        #expect(!model.isOn(.waveformZoomOut), "Zoom Out is off at 24 dB")
        model.run(.waveformZoomOut)
        #expect(model.timeline.waveformRange == .db24 && beeps == 2, "a step past 24 dB beeps and keeps 24 dB")
        await model.close()
    }

    /// The key reaches the window with the focus in a name field: the range steps, and the field keeps
    /// its text and its caret (a text field does nothing with the key, U18).
    @Test func theKeysRunWithAFieldFocused() async throws {
        let (model, _, window, view) = try await open()
        let editor = try await focusName(in: window)
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        let text = editor.string
        func key(_ character: String, code: UInt16) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .option, .function, .numericPad],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        }
        app.timeline(.waveformZoomIn, event: key("\u{F700}", code: 126), in: window)
        #expect(await shows(.db72, view, window), "Option-Command-Up zooms in")
        app.timeline(.waveformZoomReset, event: key("0", code: 29), in: window)
        #expect(await shows(.db60, view, window), "Option-Command-0 resets")
        #expect(editor.string == text && editor.selectedRange() == NSRange(location: 1, length: 0), "the field is kept")
        await model.close()
    }

    /// A new window opens at the app default, and a step in one window leaves the other window alone.
    @Test func eachWindowHasItsRange() async throws {
        let (first, _, firstWindow, firstView) = try await open()
        let other = folder.url.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let (second, _, _, secondView) = try await openLanes(
            app, try await timelinePackage(in: other, tracks: 2, seconds: 20, audio: true))
        secondView.viewWillMove(toWindow: nil)

        first.run(.waveformZoomIn)
        #expect(await shows(.db72, firstView, firstWindow))
        #expect(second.timeline.waveformRange == .db60 && secondView.lanes.inputs?.range == .db60, "the second window")

        app.waveformRangeDefault = .db96
        let third = folder.url.appending(path: "third", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: third, withIntermediateDirectories: true)
        let (new, _, newWindow, newView) = try await openLanes(
            app, try await timelinePackage(in: third, tracks: 2, seconds: 20, audio: true))
        newView.viewWillMove(toWindow: nil)
        #expect(await shows(.db96, newView, newWindow), "a new window opens at the default")
        #expect(first.timeline.waveformRange == .db72 && second.timeline.waveformRange == .db60, "open windows keep R")
        for model in [first, second, new] { await model.close() }
    }

    /// The default is in the app preferences as the dB. A value that is not a range reads as 60 dB.
    @Test func theDefaultIsStoredAndRead() throws {
        let domain = "DirigibleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let stored = AppDelegate(recordings: nil, defaults: defaults)
        #expect(stored.waveformRangeDefault == .db60, "nothing stored: 60 dB")
        stored.waveformRangeDefault = .db96
        #expect(defaults.integer(forKey: AppDelegate.waveformRangeKey) == 96)
        #expect(AppDelegate(recordings: nil, defaults: defaults).waveformRangeDefault == .db96)
        defaults.set(50, forKey: AppDelegate.waveformRangeKey)
        #expect(AppDelegate(recordings: nil, defaults: defaults).waveformRangeDefault == .db60, "50 is no range")
    }

    /// One step draws the lanes in view once, and the next draw of a clip with a ride reads the kept
    /// gains of its layers (they are in dB and do not read the range).
    @Test func aStepRedrawsOnce() async throws {
        let (model, _, window, view) = try await open()
        for (command, expected) in [(TimelineCommand.waveformZoomIn, WaveformRange.db72), (.waveformZoomIn, .db84)] {
            drawNow(window)
            let draws = view.lanes.draws
            model.run(command)
            #expect(await shows(expected, view, window))
            drawNow(window)
            #expect(view.lanes.draws == draws + 1, "a step to \(expected.rawValue) dB drew \(view.lanes.draws - draws)")
        }
        await model.close()
    }

    @Test func aStepWalksNoGainLayerAtEachRange() throws {
        var inputs = try LaneRendererTests.riddenInputs(length: LaneRendererTests.envelopeLength)
        let pixels = OwnedPixels(try #require(laneWindow(inputs, width: 400)))
        let renderer = LaneRenderer()
        pixels.draw { renderer.draw(inputs, .light, into: $0) }
        let walks = renderer.walks
        try #require(walks > 0, "the first draw walks the layers")
        for range in WaveformRange.allCases {
            inputs.range = range
            pixels.draw { renderer.draw(inputs, .light, into: $0) }
            #expect(renderer.walks == walks, "the step to \(range.rawValue) dB walked a layer")
        }
    }

    /// Each step says the new range once. A step that beeps says nothing.
    @Test func eachStepIsAnnounced() async throws {
        let (model, _, _, _) = try await open()
        let heard = OSAllocatedUnfairLock(initialState: [String]())
        try #require(model.chrome).announce = { text, _ in heard.withLock { $0.append(text) } }
        model.beep = {}

        model.run(.waveformZoomIn)
        model.run(.waveformZoomOut)
        model.run(.waveformZoomOut)
        #expect(heard.withLock { $0 } == [.db72, .db60, .db48].map { waveformAnnouncement($0) })
        model.timeline.waveformRange = .db24
        model.run(.waveformZoomOut)
        #expect(heard.withLock { $0 }.count == 3, "a beep says nothing")

        let english = try stringsTable("en")
        #expect(waveformAnnouncement(.db72, text: { english[$0.rawValue] ?? "" }) == "Waveform range 72 dB")
        await model.close()
    }

    /// Reset goes to the app default, says it, and is off while the range is the default.
    @Test func resetGoesToTheAppDefault() async throws {
        let (model, _, window, view) = try await open()
        let heard = OSAllocatedUnfairLock(initialState: [String]())
        try #require(model.chrome).announce = { text, _ in heard.withLock { $0.append(text) } }
        var beeps = 0
        model.beep = { beeps += 1 }

        #expect(!model.isOn(.waveformZoomReset), "Reset is off at the default")
        model.run(.waveformZoomReset)
        #expect(beeps == 1 && heard.withLock { $0 }.isEmpty, "Reset at the default beeps and says nothing")

        app.waveformRangeDefault = .db96
        #expect(model.isOn(.waveformZoomReset), "the default changed: Reset is on at once")
        model.run(.waveformZoomReset)
        #expect(await shows(.db96, view, window), "Reset goes to 96 dB, not to 60 dB")
        #expect(heard.withLock { $0 } == [waveformAnnouncement(.db96)])
        #expect(!model.isOn(.waveformZoomReset))
        await model.close()
    }

    /// An open window keeps its range when the default changes, and Reset follows the new default at once.
    @Test func anOpenWindowFollowsTheDefault() async throws {
        let (model, _, _, _) = try await open()
        model.timeline.waveformRange = .db96
        #expect(model.isOn(.waveformZoomReset), "R 96 dB, default 60 dB")
        app.waveformRangeDefault = .db96
        #expect(!model.isOn(.waveformZoomReset), "default 96 dB: Reset is off at once")
        #expect(model.timeline.waveformRange == .db96, "R stays")
        await model.close()
    }

    /// During a lane gesture the keys do nothing, so the preview keeps its range until the mouse-up.
    @Test func aStepWaitsForALaneGesture() async throws {
        let (model, _, window, view) = try await open()
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 100, y: 50), in: view))
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 200, y: 50), in: view))
        try #require(view.gesture.isActive, "a drag is on")
        model.run(.waveformZoomIn)
        #expect(model.timeline.waveformRange == .db60, "a step during a drag changed the range")
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 200, y: 50), in: view))
        model.run(.waveformZoomIn)
        #expect(await shows(.db72, view, window), "after the mouse-up the key steps")
        await model.close()
    }
}
