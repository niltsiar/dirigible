import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Command-wheel over the dB scale strip steps the waveform range of the window: one step for a notch,
/// one for each 40 pt of a trackpad, at most one in 100 ms, none from momentum. Over the header rows it
/// stays the horizontal zoom. 2 tracks of 20 s with a file on disk.
@Suite(.serialized) @MainActor struct WaveformZoomWheelTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func open() async throws -> (SessionWindow, NSWindow, TimelineScrollView) {
        let (model, _, window, view) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 20, audio: true))
        view.viewWillMove(toWindow: nil)
        return (model, window, view)
    }

    /// A wheel event at `time` seconds of event time. `amount` is lines of a mouse wheel, or points of
    /// a trackpad with `trackpad`; positive scrolls up.
    func wheel(
        _ amount: Int32, trackpad: Bool = false, at time: Double, phase: Int64 = 0, momentum: Int64 = 0,
        command: Bool = true
    ) throws -> NSEvent {
        let event = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil, units: trackpad ? .pixel : .line, wheelCount: 1, wheel1: amount,
                wheel2: 0, wheel3: 0))
        if trackpad { event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        if command { event.flags = .maskCommand }
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        event.timestamp = CGEventTimestamp(time * 1e9 * Double(base.denom) / Double(base.numer))
        return try #require(NSEvent(cgEvent: event))
    }

    /// The view that the window gives a wheel event at the header column x `x`.
    func hit(_ x: Double, _ view: TimelineScrollView) throws -> NSView {
        let window = try #require(view.window)
        drawNow(window)
        let point = view.headers.convert(NSPoint(x: x, y: view.headers.bounds.midY), to: nil)
        return try #require(window.contentView?.superview?.hitTest(point))
    }

    /// One notch up steps 60 to 72 dB, a notch down steps back, and a notch of five lines is one step.
    /// The lanes keep their horizontal scale.
    @Test func aWheelNotchStepsOnce() async throws {
        let (model, _, view) = try await open()
        let strip = view.headers.strip
        try #require(try hit(view.headers.columnWidth - 10, view) === strip)
        let scale = model.timeline.scale
        try strip.scrollWheel(with: wheel(1, at: 100))
        #expect(model.timeline.waveformRange == .db72, "a notch up zooms in")
        try strip.scrollWheel(with: wheel(-1, at: 100.5))
        #expect(model.timeline.waveformRange == .db60, "a notch down zooms out")
        try strip.scrollWheel(with: wheel(5, at: 101))
        #expect(model.timeline.waveformRange == .db72, "five lines are one step")
        #expect(model.timeline.scale == scale, "no horizontal zoom from the strip")
        try strip.scrollWheel(with: wheel(1, at: 102, command: false))
        #expect(model.timeline.waveformRange == .db72 && model.timeline.scale == scale, "no Command: no step")
        await model.close()
    }

    /// A notch at x `columnWidth - 3` is under the header handle, which gives it to the strip.
    @Test func aCommandWheelOnTheHandleStepsTheRange() async throws {
        let (model, _, view) = try await open()
        let scale = model.timeline.scale
        let target = try hit(view.headers.columnWidth - 3, view)
        try #require(target === view.headers.handle, "the handle covers the trailing 6 pt of the strip")
        try target.scrollWheel(with: wheel(1, at: 100))
        #expect(model.timeline.waveformRange == .db72, "one notch steps 60 to 72 dB")
        #expect(model.timeline.scale == scale, "no horizontal zoom at the handle")
        await model.close()
    }

    /// A second notch 50 ms after a step gives no step; a notch 120 ms after the step gives one. A
    /// trackpad steps for each 40 pt, and the points under 40 pt wait for the rest.
    @Test func stepsCoalesceIn100Milliseconds() async throws {
        let (model, _, view) = try await open()
        let strip = view.headers.strip
        try strip.scrollWheel(with: wheel(1, at: 100))
        try strip.scrollWheel(with: wheel(1, at: 100.05))
        #expect(model.timeline.waveformRange == .db72, "two notches 50 ms apart are one step")
        try strip.scrollWheel(with: wheel(1, at: 100.12))
        #expect(model.timeline.waveformRange == .db84, "a notch 120 ms after the step steps")

        for (time, expected) in [(101.0, WaveformRange.db84), (101.2, .db72), (101.4, .db72)] {
            try strip.scrollWheel(with: wheel(-25, trackpad: true, at: time, phase: time == 101 ? 1 : 2))
            #expect(model.timeline.waveformRange == expected, "25 pt, then 50 pt in all: one step (at \(time))")
        }
        await model.close()
    }

    /// An event of the momentum phase gives no step, also long after the last step.
    @Test func momentumGivesNoStep() async throws {
        let (model, _, view) = try await open()
        let strip = view.headers.strip
        try strip.scrollWheel(with: wheel(50, trackpad: true, at: 100, phase: 1))
        #expect(model.timeline.waveformRange == .db72, "the stroke steps once")
        for index in 0..<10 {
            try strip.scrollWheel(with: wheel(50, trackpad: true, at: 100.5 + Double(index) * 0.2, momentum: 2))
        }
        #expect(model.timeline.waveformRange == .db72, "the momentum gives no step")
        await model.close()
    }

    /// The handler draws no lane: the draw count stays and is one more after the next display.
    @Test func aWheelRunsNoDrawInline() async throws {
        let (model, window, view) = try await open()
        drawNow(window)
        let draws = view.lanes.draws
        try view.headers.strip.scrollWheel(with: wheel(1, at: 100))
        #expect(view.lanes.draws == draws, "no lane draw inside the wheel handler")
        await until(limit: .seconds(10), "the lanes draw at 72 dB") {
            window.contentView?.layoutSubtreeIfNeeded()
            return view.lanes.inputs?.range == .db72
        }
        drawNow(window)
        #expect(view.lanes.draws == draws + 1, "one draw after the next display, got \(view.lanes.draws - draws)")
        await model.close()
    }

    /// Over the header rows, out of the strip, Command-wheel is the horizontal zoom and the range stays.
    @Test func commandWheelOverTheRowsStaysTheHorizontalZoom() async throws {
        let (model, _, view) = try await open()
        let rows = try hit(100, view)
        try #require(rows !== view.headers.strip && rows !== view.headers.handle)
        let scale = model.timeline.scale
        try rows.scrollWheel(with: wheel(1, at: 100))
        #expect(model.timeline.scale != scale, "the horizontal zoom ran")
        #expect(model.timeline.waveformRange == .db60, "the range stays")
        await model.close()
    }
}
