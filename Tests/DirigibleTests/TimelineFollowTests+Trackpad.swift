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
    /// A trackpad gesture of `dx` points: 10 events with scroll phases (began, then changed), the
    /// end, 10 momentum events that slow down, and the momentum end.
    func trackpadScroll(dx: Double) throws -> [NSEvent] {
        func event(_ dx: Double, phase: Int64, momentum: Int64) throws -> NSEvent {
            let event = try #require(
                CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(dx),
                    wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            return try #require(NSEvent(cgEvent: event))
        }
        var events = try (0..<10).map { try event(dx / 10, phase: $0 == 0 ? 1 : 2, momentum: 0) }
        events.append(try event(0, phase: 4, momentum: 0))
        events += try (0..<10).map { try event(dx / 10 * Double(10 - $0) / 20, phase: 0, momentum: $0 == 0 ? 1 : 2) }
        events.append(try event(0, phase: 0, momentum: 3))
        return events
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
}
