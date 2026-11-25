import AppKit
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// Criterion P15 (run 2026-10-28-pre-roll): during the pre-roll of a take, a red line shows at T on
/// the lanes and on the ruler, drawn once, and the status text "Pre-roll" shows until T. The take
/// state is set with a pinned host clock, so the test moves the clock past H_T.
@Suite(.serialized) @MainActor struct PreRollWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    /// T = 2 s, and H_T at 5 s of the pinned clock.
    static let playhead: Frames = 96_000
    static let anchor: UInt64 = 5_000_000_000

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    /// A session window in a pre-roll take at `clock` (host nanoseconds), with no device.
    func open(clock: LockedClock, preRoll: Bool = true) async throws -> (SessionWindow, Studio) {
        let (model, studio, _, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 1, seconds: 6))
        try begin(studio, clock: clock, preRoll: preRoll)
        return (model, studio)
    }

    /// Lanes of a standalone window in a pre-roll take: the ruler has a laid out place there.
    func openStandalone(clock: LockedClock, preRoll: Bool = true) async throws
        -> (SessionWindow, Studio, TimelineScrollView)
    {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 1, seconds: 6), app: app)
        let (_, view) = standaloneLanes(model, studio)
        try begin(studio, clock: clock, preRoll: preRoll)
        return (model, studio, view)
    }

    private func begin(_ studio: Studio, clock: LockedClock, preRoll: Bool) throws {
        studio.environment.hostNanos = { clock.value }
        try studio.edit(ripple: false) { s throws(SessionError) in
            try s.setRecording(
                Recording(
                    take: 1, playheadFrame: Self.playhead, takeStartHostTimeNanos: Self.anchor,
                    armedTracks: ["t1"], isPreRoll: preRoll))
        }
        studio.transport = .recording(take: 1)
    }

    func close(_ model: SessionWindow, _ studio: Studio) async {
        studio.transport = .idle
        await model.close()
    }

    @Test func redLineAtT() async throws {
        let clock = LockedClock(Self.anchor - 1_000_000_000)
        let (model, studio, view) = try await openStandalone(clock: clock)
        let (lanes, ruler) = (view.lanes, view.ruler)
        view.displayTick()
        let draws = lanes.draws

        let edge = Double(ruler.convert(NSPoint(x: Double(view.shown.minX), y: 0), from: view.documentView).x)
        #expect(
            !lanes.preRollLine.isHidden && !ruler.preRollMark.isHidden,
            "the line shows in the pre-roll: edge \(edge) shown \(view.shown) ruler \(ruler.bounds) \(ruler.frame)")
        let x = Double(Self.playhead.count) / lanes.framesPerPoint
        #expect(
            abs(Double(lanes.preRollLine.position.x) - x) < 0.001,
            "the line is at T: \(lanes.preRollLine.position.x) not \(x)")
        let rulerX = Double(ruler.convert(NSPoint(x: x, y: 0), from: view.documentView).x)
        #expect(abs(Double(ruler.preRollMark.frame.midX) - rulerX) <= 1, "the mark is at \(ruler.preRollMark.frame)")
        view.displayTick()
        view.displayTick()
        #expect(lanes.draws == draws, "the line is a layer: no lane draw")

        clock.value = Self.anchor
        view.displayTick()
        #expect(lanes.preRollLine.isHidden && ruler.preRollMark.isHidden, "the line goes at T")
        await close(model, studio)
    }

    /// Negative control: a take that is not a pre-roll take has no line.
    @Test func aPlainTakeHasNoLine() async throws {
        let clock = LockedClock(Self.anchor - 1_000_000_000)
        let (model, studio, view) = try await openStandalone(clock: clock, preRoll: false)
        view.displayTick()

        #expect(view.lanes.preRollLine.isHidden && view.ruler.preRollMark.isHidden)
        await close(model, studio)
    }

    @Test func theStatusShowsPreRollUntilT() async throws {
        let clock = LockedClock(Self.anchor - 1_000_000_000)
        let (model, studio) = try await open(clock: clock)
        let status = L10n.subtitlePreRoll.text

        #expect(ChromeState(model: model).subtitle.hasSuffix(" · " + status), "before T")
        clock.value = Self.anchor
        #expect(!ChromeState(model: model).subtitle.contains(status), "at T")
        await close(model, studio)
    }

    @Test func theStatusValueNamesThePreRoll() {
        let english = { (key: L10n) in key == .subtitlePreRoll ? "Pre-roll" : "x" }
        #expect(
            subtitleText(
                rate: 48_000, recordTimeLeft: nil, preRoll: true, locale: Locale(identifier: "en_US"),
                text: english) == "48 kHz · Pre-roll")
    }

    /// VoiceOver hears "Pre-roll" once at the press, not at each loop turn.
    @Test func theAnnouncementComesOnce() async throws {
        let clock = LockedClock(Self.anchor - 1_000_000_000)
        let (model, studio) = try await open(clock: clock)
        let chrome = try #require(model.chrome)
        let heard = OSAllocatedUnfairLock(initialState: [String]())
        chrome.announce = { text, _ in heard.withLock { $0.append(text) } }

        chrome.update()
        chrome.update()
        chrome.update()

        #expect(heard.withLock { $0 } == [L10n.subtitlePreRoll.text])
        await close(model, studio)
    }
}

/// A host clock that a test moves.
final class LockedClock: Sendable {
    private let state: OSAllocatedUnfairLock<UInt64>
    init(_ start: UInt64) { state = OSAllocatedUnfairLock(initialState: start) }
    var value: UInt64 {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
