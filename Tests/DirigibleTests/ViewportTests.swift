import DirigibleAudio
import DirigibleCore
import Testing

@testable import DirigibleApp
@testable import DirigibleTimeline

/// The zoom, follow, and playhead rules of decision 0017 (timeline-view criteria 13 to 15): the
/// zoom and follow tables in the run design, with literal frames. The view is 1440 pt wide at
/// 512 frames per point (737,280 visible frames) unless a test says otherwise.
struct ViewportTests {
    static let twoHours = Frames(48_000 * 7200)

    @Test func theZoomStopsAtOneTwentyEightFramesPerPointAndAtTheFitOfTheEnd() {
        let limits = TimelineScale.limits(end: Self.twoHours, rate: 48_000, width: 1440)

        #expect(limits == 128...244_800, "the closest zoom, and 2 h + 2% over 1440 pt")
        // Zoom in from 256 goes to 128; from 128 it stays.
        let origin = TimelineScale(framesPerPoint: 256).zoomed(by: 0.5, anchor: 1_000_000, at: 400, limits: limits)
        #expect(origin.scale.framesPerPoint == 128 && origin.origin == 948_800)
        #expect(
            TimelineScale(framesPerPoint: 128).zoomed(by: 0.5, anchor: 0, at: 0, limits: limits).scale.framesPerPoint
                == 128)
        // Zoom out at the fit stays.
        #expect(
            TimelineScale(framesPerPoint: 244_800).zoomed(by: 2, anchor: 0, at: 0, limits: limits).scale.framesPerPoint
                == 244_800)
    }

    /// Over 2^23 points of document width, the closest zoom moves out (probe D6).
    @Test func aLongSessionHasAFartherClosestZoom() {
        #expect(TimelineScale.limits(end: Frames(8_388_608 * 300), rate: 48_000, width: 1440).lowerBound == 300)
    }

    /// A short session fits 10 s (+ 2%), not its end.
    @Test func aShortSessionFitsTenSeconds() {
        #expect(TimelineScale.limits(end: 48_000, rate: 48_000, width: 1440).upperBound == 340)
        #expect(TimelineScale.limits(end: 0, rate: 48_000, width: 1440).upperBound == 340)
        // A view wider than 10 s at the closest zoom: the range holds one scale.
        #expect(TimelineScale.limits(end: 0, rate: 48_000, width: 5000) == 128...128)
    }

    @Test func zoomInHalvesAndZoomOutDoublesAtTheAnchor() {
        let limits = TimelineScale.limits(end: Self.twoHours, rate: 48_000, width: 1440)
        let scale = TimelineScale(framesPerPoint: 512)

        let zoomedIn = scale.zoomed(by: 0.5, anchor: 1_000_000, at: 400, limits: limits)
        let zoomedOut = scale.zoomed(by: 2, anchor: 1_000_000, at: 400, limits: limits)

        #expect(zoomedIn.scale.framesPerPoint == 256 && zoomedIn.origin == 897_600)
        #expect(zoomedOut.scale.framesPerPoint == 1024 && zoomedOut.origin == 590_400)
        // The origin never goes before 0.
        #expect(scale.zoomed(by: 2, anchor: 100_000, at: 400, limits: limits).origin == 0)
    }

    @Test func theKeysAnchorAtThePlayheadWhenItIsInView() {
        let anchor = zoomAnchor(playhead: 100_000, origin: 0, width: 1440, scale: TimelineScale(framesPerPoint: 512))

        #expect(anchor.frame == 100_000 && anchor.x == 195.3125)
    }

    @Test func theKeysAnchorAtTheCenterWhenThePlayheadIsOutOfView() {
        let scale = TimelineScale(framesPerPoint: 512)

        let after = zoomAnchor(playhead: 800_000, origin: 0, width: 1440, scale: scale)
        let before = zoomAnchor(playhead: 100, origin: 1_000_000, width: 1440, scale: scale)

        #expect(after.frame == 368_640 && after.x == 720)
        #expect(before.frame == 1_368_640 && before.x == 720)
    }

    @Test func zoomToSessionShowsTheEndPlusTwoPercent() {
        let limits = TimelineScale.limits(end: Self.twoHours, rate: 48_000, width: 1440)

        #expect(TimelineScale.fit(end: Self.twoHours, width: 1440, limits: limits).framesPerPoint == 244_800)
        #expect(TimelineScale.fit(end: 480_000, width: 1440, limits: limits).framesPerPoint == 340)
    }

    @Test func zoomToSelectionShowsTheRangeWithFivePercentEachSide() {
        let limits = TimelineScale.limits(end: Self.twoHours, rate: 48_000, width: 1440)

        let fit = TimelineScale.fit(480_000..<960_000, width: 1440, limits: limits)
        let short = TimelineScale.fit(480_000..<481_000, width: 1440, limits: limits)

        #expect(abs(fit.scale.framesPerPoint - 366.667) < 0.001 && fit.origin == 456_000)
        #expect(short.scale.framesPerPoint == 128 && short.origin == 479_950)
    }

    @Test func followTurnsAtNinetyFourPercent() {
        #expect(followOrigin(playhead: 693_043, origin: 0, frames: 737_280, direction: .forward) == nil)
        #expect(followOrigin(playhead: 693_044, origin: 0, frames: 737_280, direction: .forward) == 611_943)
    }

    @Test func reverseFollowTurnsAtSixPercent() {
        #expect(followOrigin(playhead: 1_044_237, origin: 1_000_000, frames: 737_280, direction: .reverse) == nil)
        #expect(
            followOrigin(playhead: 1_044_236, origin: 1_000_000, frames: 737_280, direction: .reverse) == 388_057)
    }

    /// A seek or a play start with the playhead off the page: 11% (reverse: 89%), never before 0.
    @Test func aPlayheadOffThePageTurnsToIt() {
        #expect(followOrigin(playhead: 2_000_000, origin: 0, frames: 737_280, direction: .forward) == 1_918_899)
        #expect(followOrigin(playhead: 500_000, origin: 1_000_000, frames: 737_280, direction: .forward) == 418_899)
        #expect(followOrigin(playhead: 50_000, origin: 1_000_000, frames: 737_280, direction: .forward) == 0)
        #expect(followOrigin(playhead: 1_000_000, origin: 0, frames: 737_280, direction: .reverse) == 343_821)
    }

    @Test func aUserScrollHoldsTheFollowWhileThePlayheadIsOutOfView() {
        var state = TimelineState()
        state.followHeld = true

        #expect(state.follow(playhead: 800_000, origin: 0, frames: 737_280, direction: .forward) == nil)
        #expect(state.followHeld)
    }

    @Test func theFollowComesBackWhenThePlayheadIsInViewAgain() {
        var state = TimelineState()
        state.followHeld = true

        #expect(state.follow(playhead: 800_000, origin: 0, frames: 737_280, direction: .forward) == nil)
        #expect(state.follow(playhead: 100_000, origin: 0, frames: 737_280, direction: .forward) == nil)
        #expect(!state.followHeld)
        #expect(state.follow(playhead: 693_044, origin: 0, frames: 737_280, direction: .forward) == 611_943)
    }

    /// V3: a scroll that starts with the head in view holds the follow until the head leaves the
    /// view and comes back, also past 94%. A new hold starts with the head in the view.
    @Test func aHoldWithTheHeadInViewWaitsForTheHeadToLeave() {
        var state = TimelineState()
        state.followHeld = true

        #expect(state.follow(playhead: 100_000, origin: 0, frames: 737_280, direction: .forward) == nil)
        #expect(state.follow(playhead: 720_000, origin: 0, frames: 737_280, direction: .forward) == nil)
        #expect(state.followHeld, "the head did not leave the view")

        #expect(state.follow(playhead: 800_000, origin: 0, frames: 737_280, direction: .forward) == nil)
        state.followHeld = false
        state.followHeld = true
        #expect(state.follow(playhead: 720_000, origin: 0, frames: 737_280, direction: .forward) == nil)
        #expect(state.followHeld, "the end of a hold clears the head that left the view")
    }

    @Test func followOffNeverMovesTheOrigin() {
        var state = TimelineState()
        state.follows = false

        #expect(state.follow(playhead: 2_000_000, origin: 0, frames: 737_280, direction: .forward) == nil)
    }

    @Test func extrapolationStopsFiftyMillisecondsAfterThePoll() {
        let poll = ContinuousClock.now
        let forward = Playback.playing(Shuttle(direction: .forward, rate: .one))
        let reverse = Playback.playing(Shuttle(direction: .reverse, rate: .two))
        func at(_ milliseconds: Int, _ playback: Playback) -> Double {
            playheadFrame(
                polled: 48_000, at: poll, now: poll + .milliseconds(milliseconds), playback: playback, rate: 48_000)
        }

        #expect(abs(at(20, forward) - 48_960) < 0.01)
        #expect(abs(at(20, reverse) - 46_080) < 0.01)
        // A stalled Player: the line stops 50 ms after the poll.
        #expect(abs(at(1000, forward) - 50_400) < 0.01)
        #expect(at(1000, .stopped) == 48_000)
    }
}

/// The record-over overlay (criterion 19): 8 tracks, each with the clips of `clips` (by default one
/// clip at 0 ..< 1,000,000), 5 lanes in view, and the frames 0 ..< 737,280 in view.
struct RecordOverTests {
    static func session(clips: [Range<Frames>] = [0..<1_000_000]) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 1_000_000))
        for n in 1...8 {
            try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono)
            for (i, range) in clips.enumerated() {
                let clip = Clip(
                    id: ClipID("c\(n)-\(i)"), file: "f", start: range.lowerBound, offset: 0,
                    length: range.upperBound - range.lowerBound)
                try session.place(clip, on: TrackID("t\(n)"))
            }
        }
        return session
    }

    static let visible = TimelineVisible(frames: 0..<737_280, lanes: 0..<5)

    static func warns(_ armed: Set<TrackID>, _ playhead: Frames, clips: [Range<Frames>] = [0..<1_000_000]) throws
        -> Bool
    {
        recordOverHidden(session: try session(clips: clips), armed: armed, playhead: playhead, visible: visible)
    }

    @Test func anArmedClipInAClippedLaneWarns() throws {
        #expect(try Self.warns(["t7"], 100_000), "an armed clip in a clipped lane warns")
    }

    @Test func anArmedClipInViewDoesNotWarn() throws {
        #expect(try !Self.warns(["t2"], 100_000), "an armed clip in view does not warn")
    }

    @Test func aPlayheadOutOfViewWarns() throws {
        #expect(try Self.warns(["t2"], 800_000), "a playhead out of view warns")
    }

    @Test func noClipAtOrAfterThePlayheadDoesNotWarn() throws {
        #expect(try !Self.warns(["t7"], 1_500_000), "no clip at or after the playhead does not warn")
    }

    /// Before the first layout nothing is in view.
    @Test func noLayoutYetWarnsForAClip() throws {
        let session = try Self.session()
        #expect(
            recordOverHidden(session: session, armed: ["t2"], playhead: 100_000, visible: nil),
            "before a layout a clip at the playhead warns")
        #expect(
            !recordOverHidden(session: session, armed: ["t2"], playhead: 1_500_000, visible: nil),
            "before a layout no clip does not warn")
    }

    /// A take replaces from the playhead on, so a clip after a gap counts.
    @Test func aClipAfterThePlayheadInAClippedLaneWarns() throws {
        #expect(
            try Self.warns(["t7"], 100_000, clips: [200_000..<1_000_000]),
            "a clip after the playhead in a clipped lane warns")
    }

    @Test func aClipAfterThePlayheadOutOfViewWarns() throws {
        #expect(
            try Self.warns(["t2"], 100_000, clips: [800_000..<1_000_000]),
            "a clip that starts after the visible frames warns")
    }

    /// Decision 0017: the lanes draw a clip in view.
    @Test func aClipAfterThePlayheadInViewDoesNotWarn() throws {
        #expect(
            try !Self.warns(["t2"], 100_000, clips: [200_000..<1_000_000]),
            "a clip after the playhead in view does not warn")
    }

    @Test func noLayoutYetWarnsForAClipAfterThePlayhead() throws {
        let session = try Self.session(clips: [200_000..<1_000_000])
        #expect(
            recordOverHidden(session: session, armed: ["t2"], playhead: 100_000, visible: nil),
            "before a layout a clip after the playhead warns")
    }

    @Test func aClipThatEndsAtThePlayheadDoesNotWarn() throws {
        #expect(try !Self.warns(["t7"], 1_000_000), "a clip that ends at the playhead does not warn")
        #expect(try Self.warns(["t7"], 999_999), "the last frame of a clip warns")
    }

    @Test func theFirstClipThatRecordReachesCounts() throws {
        #expect(
            try Self.warns(["t2"], 100_000, clips: [0..<50_000, 800_000..<1_000_000]),
            "a clip that ends before the playhead does not count")
    }

    /// The accepted case A1 of the plan gate: only the first clip that Record reaches counts. When it
    /// is in view, the user sees that Record reaches audio on that track.
    @Test func aLaterClipOutOfViewBehindAClipInViewDoesNotWarn() throws {
        #expect(
            try !Self.warns(["t2"], 100_000, clips: [200_000..<300_000, 800_000..<1_000_000]),
            "a later clip out of view behind a clip in view does not warn")
    }

    @Test func theWarningNamesTheRangeThatRecordReplaces() {
        let texts = [
            "en": "Record replaces audio out of view on an armed track, from the playhead on. "
                + "Choose Go to End or turn off Arm to keep it.",
            "es": "Grabar sustituye audio fuera de la vista en una pista armada, desde el cursor. "
                + "Elige Ir al final o desactiva Armar para conservarlo.",
        ]
        for (language, text) in texts {
            let table = (try? stringsTable(language)) ?? [:]
            #expect(table["transport.record.over"] == text, "\(language) record-over text")
        }
    }
}
