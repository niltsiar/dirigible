import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The readout of the range in the ruler band over the track headers, the menu of the ranges, and the
/// double click on the scale strip.
extension WaveformZoomWindowTests {
    func readouts(in window: NSWindow) -> [ReadoutView] {
        func found(_ view: NSView) -> [ReadoutView] {
            ((view as? ReadoutView).map { [$0] } ?? []) + view.subviews.flatMap(found)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return window.contentView.map(found) ?? []
    }

    /// Waits until the window shows `count` readouts.
    func showsReadouts(_ count: Int, in window: NSWindow) async -> Bool {
        await until(limit: .seconds(10), "the window shows \(count) readouts") { readouts(in: window).count == count }
        return readouts(in: window).count == count
    }

    func rightClick(_ view: NSView, in window: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: view.convert(NSPoint(x: 5, y: 5), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1))
    }

    /// The readout shows the range while it is not the app default, and nothing at the default.
    @Test func theRangeTextShowsOffTheDefault() async throws {
        let (model, _, window, _) = try await open()
        let english = try stringsTable("en")
        #expect(await showsReadouts(0, in: window), "default 60 dB and R 60 dB: no readout")
        for (range, text) in [(WaveformRange.db96, "96 dB"), (.db24, "24 dB")] {
            model.timeline.waveformRange = range
            #expect(await showsReadouts(1, in: window))
            #expect(readouts(in: window).first?.title == waveformRangeText(range), "R \(range.rawValue) dB")
            #expect(waveformRangeText(range, text: { english[$0.rawValue] ?? "" }) == text)
        }
        app.waveformRangeDefault = .db96
        model.timeline.waveformRange = .db96
        #expect(await showsReadouts(0, in: window), "default 96 dB and R 96 dB: no readout")
        model.timeline.waveformRange = .db60
        #expect(await showsReadouts(1, in: window))
        #expect(readouts(in: window).first?.title == waveformRangeText(.db60), "default 96 dB and R 60 dB")
        await model.close()
    }

    /// The readout is one button for VoiceOver with the label of the announcement. A press resets, and the
    /// show-menu action shows the menu.
    @Test func theReadoutIsOneButton() async throws {
        let (model, _, window, view) = try await open()
        model.timeline.waveformRange = .db96
        try #require(await showsReadouts(1, in: window))
        let readout = try #require(readouts(in: window).first)
        #expect(readout.accessibilityRole() == .button)
        #expect(readout.accessibilityLabel() == waveformAnnouncement(.db96))
        #expect((readout.accessibilityChildren() ?? []).isEmpty, "the text is not a second element")

        var menus: [NSMenu] = []
        readout.present = { menu, _ in menus.append(menu) }
        #expect(readout.accessibilityPerformShowMenu() && menus.count == 1)
        #expect(menus.first?.items.filter { !$0.isSeparatorItem }.count == WaveformRange.allCases.count + 1)

        #expect(readout.accessibilityPerformPress(), "the press action resets")
        #expect(await shows(.db60, view, window))
        #expect(await showsReadouts(0, in: window), "the readout goes at the default")
        await model.close()
    }

    /// The text is `secondaryLabelColor`, and `labelColor` with Increase Contrast.
    @Test func theRangeTextColorFollowsIncreaseContrast() {
        #expect(ReadoutView.color(increasesContrast: false) == .secondaryLabelColor)
        #expect(ReadoutView.color(increasesContrast: true) == .labelColor)
    }

    /// A change of the app default shows or hides the readout of an open window at once.
    @Test func theReadoutFollowsTheDefault() async throws {
        let (model, _, window, _) = try await open()
        model.timeline.waveformRange = .db96
        #expect(await showsReadouts(1, in: window))
        app.waveformRangeDefault = .db96
        #expect(await showsReadouts(0, in: window), "R 96 dB, default 96 dB: the readout goes at once")
        #expect(model.timeline.waveformRange == .db96, "R stays")
        app.waveformRangeDefault = .db60
        #expect(await showsReadouts(1, in: window), "default 60 dB again: the readout comes back")
        await model.close()
    }

    /// The menu of the strip and of the readout has the nine ranges with a check on the range of the
    /// window, then Reset, which is off at the app default.
    @Test func theRangeMenuChecksTheCurrentRange() async throws {
        let (model, _, window, view) = try await open()
        let strip = view.headers.strip
        var menu = try #require(strip.menu(for: try rightClick(strip, in: window)))
        let ranges = menu.items.dropLast().filter { !$0.isSeparatorItem }
        #expect(ranges.map(\.tag) == WaveformRange.allCases.map(\.rawValue) && ranges.count == 9, "nine ranges")
        #expect(ranges.map(\.title) == WaveformRange.allCases.map { waveformRangeText($0) })
        #expect(ranges.map(\.state) == WaveformRange.allCases.map { $0 == .db60 ? .on : .off })
        #expect(menu.items.last?.title == L10n.menuViewWaveformZoomReset.text)
        #expect(menu.items.last?.isEnabled == false, "Reset is off at the default")

        model.timeline.waveformRange = .db96
        menu = try #require(strip.menu(for: try rightClick(strip, in: window)))
        #expect(menu.items.first { $0.state == .on }?.tag == 96)
        #expect(menu.items.last?.isEnabled == true)
        await model.close()
    }

    /// A choice sets the range of this window only, draws the lanes once, and says it. A choice of the
    /// current range gives no draw and no post. Reset goes to the app default.
    @Test func theRangeMenuSetsTheRange() async throws {
        let (first, _, window, view) = try await open()
        let other = folder.url.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let (second, _, _, _) = try await openLanes(
            app, try await timelinePackage(in: other, tracks: 2, seconds: 20, audio: true))
        let heard = OSAllocatedUnfairLock(initialState: [String]())
        try #require(first.chrome).announce = { text, _ in heard.withLock { $0.append(text) } }

        let strip = view.headers.strip
        let menu = try #require(strip.menu(for: try rightClick(strip, in: window)))
        drawNow(window)
        let draws = view.lanes.draws
        menu.performActionForItem(at: menu.indexOfItem(withTag: 84))
        #expect(await shows(.db84, view, window))
        drawNow(window)
        #expect(view.lanes.draws == draws + 1, "the choice drew \(view.lanes.draws - draws) times")
        #expect(heard.withLock { $0 } == [waveformAnnouncement(.db84)])
        #expect(second.timeline.waveformRange == .db60, "the other window keeps its range")

        let again = try #require(strip.menu(for: try rightClick(strip, in: window)))
        again.performActionForItem(at: again.indexOfItem(withTag: 84))
        drawNow(window)
        #expect(
            view.lanes.draws == draws + 1 && heard.withLock { $0 }.count == 1, "the current range: no draw, no post")

        let reset = try #require(strip.menu(for: try rightClick(strip, in: window)))
        reset.performActionForItem(at: reset.items.count - 1)
        #expect(await shows(.db60, view, window))
        #expect(heard.withLock { $0 } == [waveformAnnouncement(.db84), waveformAnnouncement(.db60)])
        for model in [first, second] { await model.close() }
    }

    /// A double click on the strip resets the range of the window. At the app default it does nothing: no
    /// post and no beep. One click does not reset.
    @Test func aDoubleClickOnTheStripResets() async throws {
        let (model, _, window, view) = try await open()
        let heard = OSAllocatedUnfairLock(initialState: [String]())
        try #require(model.chrome).announce = { text, _ in heard.withLock { $0.append(text) } }
        var beeps = 0
        model.beep = { beeps += 1 }
        let strip = view.headers.strip
        func click(_ count: Int) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: strip.convert(NSPoint(x: 5, y: 40), to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                    pressure: 1))
        }

        strip.mouseDown(with: try click(2))
        #expect(heard.withLock { $0 }.isEmpty && beeps == 0, "a double click at the default does nothing")

        model.timeline.waveformRange = .db96
        strip.mouseDown(with: try click(1))
        #expect(model.timeline.waveformRange == .db96, "one click does not reset")
        strip.mouseDown(with: try click(2))
        #expect(await shows(.db60, view, window))
        #expect(heard.withLock { $0 } == [waveformAnnouncement(.db60)])
        await model.close()
    }
}
