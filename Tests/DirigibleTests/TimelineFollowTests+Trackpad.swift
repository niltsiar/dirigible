import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// A trackpad scroll back during a take or a play, with the head in view at its start (Phase 7
/// finding V3, criterion C32, decision 0017). The events have the scroll phases and the momentum
/// phases of `scripts/hid.swift scroll --phases`, and a display tick comes after each event.
extension TimelineFollowTests {
    /// A trackpad gesture of `dx` and `dy` points: 10 events with scroll phases (began, then
    /// changed), the end, 10 momentum events that slow down, and the momentum end.
    func trackpadScroll(dx: Double, dy: Double = 0) throws -> [NSEvent] {
        func event(_ part: Double, phase: Int64, momentum: Int64) throws -> NSEvent {
            let event = try #require(
                CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy * part),
                    wheel2: Int32(dx * part), wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            return try #require(NSEvent(cgEvent: event))
        }
        var events = try (0..<10).map { try event(0.1, phase: $0 == 0 ? 1 : 2, momentum: 0) }
        events.append(try event(0, phase: 4, momentum: 0))
        events += try (0..<10).map { try event(0.1 * Double(10 - $0) / 20, phase: 0, momentum: $0 == 0 ? 1 : 2) }
        events.append(try event(0, phase: 0, momentum: 3))
        return events
    }

    /// A user scroll to `frame` as AppKit gives it: a live scroll that moves the view. A synthetic
    /// wheel event does not move the clip view of the test process (test-harness.md).
    func liveScroll(_ view: TimelineScrollView, toFrame frame: Double) {
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: view)
        view.scroll(toFrame: frame)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
    }

    /// Ticks of 8,000 frames from `head` while `more` is true, each with its draw. The head
    /// after them and the page turns. Each tick frees the main actor for the other suites: a
    /// loop that held it made the play of `ChromeTests.aPlayRunsNoSwiftUIBody` reach its end.
    func ticks(
        _ view: TimelineScrollView, _ window: NSWindow, from head: Double, playback: Playback, taking: Bool,
        while more: (Double) -> Bool
    ) async -> (head: Double, turns: Int) {
        var (head, turns) = (head, 0)
        while more(head) {
            head += 8_000
            let origin = view.origin
            view.tick(playhead: head, playback: playback, taking: taking)
            drawNow(window)
            if view.origin != origin { turns += 1 }
            await Task.yield()
        }
        return (head, turns)
    }

    /// From the take start or the play start: the head at 40% of the second page or later, the
    /// gesture with a tick of 800 frames after each event, then the ticks until the head is
    /// past the right edge. The origin before and after the gesture, and the turns after it.
    func scrollBack(_ view: TimelineScrollView, _ window: NSWindow, playback: Playback, taking: Bool) async throws
        -> (start: Double, origin: Double, turns: Int)
    {
        var (head, _) = await ticks(view, window, from: 0, playback: playback, taking: taking) { head in
            view.origin == 0 || (head - view.origin) / view.visibleFrames < 0.4
        }
        let start = view.origin
        for event in try trackpadScroll(dx: 800) {
            view.scrollWheel(with: event)
            // The clip view of the test process does not move for these events, and an HID
            // scroll moves it (test-harness.md). The test moves it by the delta of the event.
            view.scroll(toFrame: view.origin - Double(event.scrollingDeltaX) * view.framesPerPoint)
            head += 800
            view.tick(playhead: head, playback: playback, taking: taking)
            drawNow(window)
            await Task.yield()
        }
        // The test process posts the didEnd of a gesture only some of the time: the app posts it.
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
        #expect(view.liveScrollOrigin == nil, "the live scroll ended")
        let origin = view.origin
        let after = await ticks(view, window, from: head, playback: playback, taking: taking) { head in
            head < origin + 1.2 * view.visibleFrames
        }
        return (start, origin, after.turns)
    }

    @Test func aTrackpadScrollBackDuringATakeHoldsTheFollow() async throws {
        let lanes = try await take()
        let (model, view) = (lanes.model, lanes.view)

        let (start, origin, turns) = try await scrollBack(view, lanes.window, playback: .stopped, taking: true)

        #expect(origin < start - 0.4 * view.visibleFrames, "the gesture scrolled back: \(start) to \(origin)")
        #expect(model.timeline.followHeld, "a trackpad scroll in a take holds the follow")
        #expect(turns == 0 && view.origin == origin, "no turn while held: \(origin) to \(view.origin)")
        await lanes.close()
    }

    /// The sibling of the take test during play, at 512 frames per point.
    @Test func aTrackpadScrollBackDuringPlayHoldsTheFollow() async throws {
        let (model, studio, window, view) = try await lanes()
        studio.environment.playerOutput = .offline
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        let playback = studio.playback
        view.tick(playhead: 0, playback: playback)

        let (start, origin, turns) = try await scrollBack(view, window, playback: playback, taking: false)

        #expect(origin < start - 0.4 * view.visibleFrames, "the gesture scrolled back: \(start) to \(origin)")
        #expect(model.timeline.followHeld, "a trackpad scroll during play holds the follow")
        #expect(turns == 0 && view.origin == origin, "no turn while held: \(origin) to \(view.origin)")
        #expect(studio.playback == Self.forward, "the play goes on")
        await studio.perform(.playStop)
        window.close()
        await model.close()
    }

    /// A scroll that does not move the view horizontally sets no hold. Such a hold never ended,
    /// and the record head went off the view.
    @Test func aVerticalScrollDuringATakeKeepsTheFollow() async throws {
        let lanes = try await take()
        let (model, view, window) = (lanes.model, lanes.view, lanes.window)
        var (head, _) = await ticks(view, window, from: 0, playback: .stopped, taking: true) { head in
            view.origin == 0 || (head - view.origin) / view.visibleFrames < 0.4
        }
        let start = view.origin
        for event in try trackpadScroll(dx: 0, dy: -200) {
            view.scrollWheel(with: event)
            head += 800
            view.tick(playhead: head, playback: .stopped, taking: true)
            drawNow(window)
            await Task.yield()
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
        #expect(view.liveScrollOrigin == nil, "the live scroll ended")
        #expect(view.origin == start, "a vertical gesture keeps the origin")
        let after = await ticks(view, window, from: head, playback: .stopped, taking: true) { head in
            head < start + 1.2 * view.visibleFrames
        }

        #expect(after.turns >= 1, "the page turns at 94%")
        let held = model.timeline.followHeld
        #expect(!held, "a vertical scroll holds nothing")
        #expect(after.head >= view.origin && after.head < view.origin + view.visibleFrames, "the head is in view")
        await lanes.close()
    }

    /// A live scroll (a scroller knob drag) with no horizontal move sets no hold.
    @Test func aLiveScrollWithNoMoveKeepsTheFollow() async throws {
        let lanes = try await take()
        let (model, view, window) = (lanes.model, lanes.view, lanes.window)
        let (head, _) = await ticks(view, window, from: 0, playback: .stopped, taking: true) { head in
            view.origin == 0 || (head - view.origin) / view.visibleFrames < 0.4
        }
        let start = view.origin
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: view)
        view.tick(playhead: head + 800, playback: .stopped, taking: true)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
        let after = await ticks(view, window, from: head + 800, playback: .stopped, taking: true) { head in
            head < start + 1.2 * view.visibleFrames
        }

        #expect(after.turns >= 1, "the page turns at 94%")
        let held = model.timeline.followHeld
        #expect(!held, "a live scroll with no move holds nothing")
        await lanes.close()
    }

    /// A knob drag back: no page turn during the drag, and a hold at its end.
    @Test func aLiveScrollThatMovesHolds() async throws {
        let lanes = try await take()
        let (model, view, window) = (lanes.model, lanes.view, lanes.window)
        let (head, _) = await ticks(view, window, from: 0, playback: .stopped, taking: true) { head in
            view.origin == 0 || (head - view.origin) / view.visibleFrames < 0.4
        }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: view)
        view.scroll(toFrame: view.origin - 0.5 * view.visibleFrames)
        let origin = view.origin
        let during = await ticks(view, window, from: head, playback: .stopped, taking: true) { head in
            head < origin + 1.2 * view.visibleFrames
        }
        #expect(during.turns == 0, "no page turn during the drag")
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
        let after = await ticks(view, window, from: during.head, playback: .stopped, taking: true) { head in
            head < origin + 1.5 * view.visibleFrames
        }

        let held = model.timeline.followHeld
        #expect(held, "a knob drag that moved the view holds the follow")
        #expect(after.turns == 0 && view.origin == origin, "no turn while held: \(origin) to \(view.origin)")
        await lanes.close()
    }

    /// Page Previous at the start of the session does not move the view, so it sets no hold.
    @Test func aPagePreviousAtTheStartDuringATakeKeepsTheFollow() async throws {
        let lanes = try await take()
        let (model, view, window) = (lanes.model, lanes.view, lanes.window)
        let (head, _) = await ticks(view, window, from: 0, playback: .stopped, taking: true) { head in
            head / view.visibleFrames < 0.4
        }
        #expect(view.origin == 0, "the first page")

        // The command of Page Previous (Option-Page Up).
        view.navigate(.page(.backward))
        #expect(view.origin == 0, "Page Previous at the start does not move the view")
        let after = await ticks(view, window, from: head, playback: .stopped, taking: true) { head in
            head < 1.2 * view.visibleFrames
        }

        #expect(after.turns >= 1, "the page turns at 94%")
        let held = model.timeline.followHeld
        #expect(!held, "a Page Previous with no move holds nothing")
        await lanes.close()
    }
}
