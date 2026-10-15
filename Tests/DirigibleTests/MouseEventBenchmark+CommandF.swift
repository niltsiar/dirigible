import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// The Command-F benches of the 2 h fixture (decisions 0035 and 0036): the fades of every clip,
/// and the crossfades of every join.
extension MouseEventBenchmark {
    /// The fixture with no fades and a gap of 1 frame before each clip but the first of a track, so
    /// no clip touches a neighbor: Command-F on Select All fades every clip and makes no crossfade
    /// (no butt join, decisions 0035 and 0036). One `setClips` call per track: 12,000 `clear`
    /// calls take minutes in debug.
    static func gappedFixture() throws -> Session {
        var (session, _) = try fixture()
        for track in session.tracks {
            let clips = track.clips.enumerated().map { index, clip in
                var clip = clip
                clip.fades = .zero
                if index > 0 {
                    clip.start += 1
                    clip.offset += 1
                    clip.length -= 1
                }
                return clip
            }
            try session.clear(.zero..<Frames(frames), on: [track.id])
            try session.setClips(clips, on: track.id)
        }
        return session
    }

    /// The events per zoom of the Command-F benches: 5 not timed, then 20 timed. A debug run
    /// times 2, so its p50 is its max: it checks only the counts, and the limits only print.
    #if DEBUG
        static let commandFEvents = 7
    #else
        static let commandFEvents = 25
    #endif

    /// The limits of B2 and C26 (`make bench`): the p50 is under 50 ms (3 frames at 60 Hz), and
    /// the max is not more than 100 ms, the limit where a one-shot response feels instant.
    static let commandFLimits = (p50: Duration.milliseconds(50) - .nanoseconds(1), max: Duration.milliseconds(100))

    /// Applies `commandFLimits` to the result of each zoom.
    static func expectFitsThreeFrames(_ results: [(p50: Duration, max: Duration)], _ name: String) {
        for ((zoom, _), result) in zip(zooms, results) {
            expectWithinBudget(result.p50, commandFLimits.p50, "\(name) p50 \(zoom): \(result.p50), not under 50 ms")
            expectWithinBudget(result.max, commandFLimits.max, "\(name) max \(zoom): \(result.max), over 100 ms")
        }
    }

    /// Fades C26: Command-F on Select All at 2 h (12,000 clips with no fade and no butt join before
    /// each event): the edit, `changedFrames`, the SwiftUI update, and the draw, within
    /// `commandFLimits`. Each event must fade every clip. A debug run checks only the counts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aCommandFOnSelectAllFitsThreeFrames() async throws {
        let gapped = try Self.gappedFixture()
        let standard = try #require(Fades(fadeIn: 24_000, fadeOut: 24_000))
        var faded: [Int] = []
        let fade = try await NavigationKeyBenchmark.measure("fade", budget: 100_000, events: Self.commandFEvents) {
            model, event in
            if let studio = model.studio {
                // The count of the last event, before the reset.
                if event > 0 {
                    faded.append(studio.session.tracks.reduce(0) { $0 + $1.clips.count { $0.fades == standard } })
                }
                try? studio.edit(ripple: false) { s throws(SessionError) in s = gapped }
                model.timeline.marks = Marks.all(in: studio.session)
            }
            return { model.run(.fade) }
        }
        #expect(
            faded.count == Self.zooms.count * (Self.commandFEvents - 1) && faded.allSatisfy { $0 == 12_000 },
            "each Command-F fades 12,000 clips: \(faded.count) events, \(Set(faded))")
        Self.expectFitsThreeFrames(fade, "fade")
    }

    /// The fixture with no fades and two files on each track, which alternate: clip k of track n
    /// is at k x 172,800 with frames from 172,800 of file n (k even) or from 345,600 of the next
    /// file (k odd). So each of the 11,994 joins has handles and is not seamless. Doubling pastes
    /// make it in 11 edits: 12,000 `place` calls take minutes in debug.
    static func joinedFixture() throws -> Session {
        let length = frames / 2000
        var session = Session(sampleRate: 48_000)
        let tracks = (1...6).map { TrackID("t\($0)") }
        for (n, track) in tracks.enumerated() {
            try session.addFile(
                AudioFile(id: FileID("f\(n + 1)"), path: "take1-\(n + 1).wav", layout: .mono, length: Frames(frames)))
            try session.addTrack(track, name: "T\(n + 1)", layout: .mono)
        }
        for (n, track) in tracks.enumerated() {
            for k in 0..<2 {
                let clip = Clip(
                    id: ClipID("j\(n + 1)-\(k)"), file: FileID("f\((n + k) % 6 + 1)"), start: Frames(k * length),
                    offset: Frames((k + 1) * length), length: Frames(length))
                try session.place(clip, on: track)
            }
        }
        var count = 2
        while count < 2000 {
            let copied = min(count, 2000 - count)
            let excerpt = try session.excerpt(of: .zero..<Frames(copied * length), on: tracks)
            try session.paste(excerpt, at: Frames(count * length), on: tracks)
            count += copied
        }
        return session
    }

    /// B2: Command-F on Select All of `joinedFixture` (decision 0036): 11,994 crossfades and the
    /// fades of the 12 free edges, `changedFrames`, the SwiftUI update, and the draw, within
    /// `commandFLimits`. Each event must make every crossfade. A debug run checks only the counts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aCommandFOnJoinsFitsThreeFrames() async throws {
        let joined = try Self.joinedFixture()
        #expect(joined.tracks.allSatisfy { $0.clips.count == 2000 && $0.clips.last?.end == Frames(Self.frames) })
        var made: [Int] = []
        let crossfade = try await NavigationKeyBenchmark.measure(
            "crossfade", budget: 100_000, events: Self.commandFEvents
        ) { model, event in
            if let studio = model.studio {
                // The count of the last event, before the reset.
                if event > 0 {
                    made.append(studio.session.tracks.reduce(0) { $0 + $1.clips.count { $0.crossfades.end != .zero } })
                }
                try? studio.edit(ripple: false) { s throws(SessionError) in s = joined }
                model.timeline.marks = Marks.all(in: studio.session)
            }
            return { model.run(.fade) }
        }
        #expect(
            made.count == Self.zooms.count * (Self.commandFEvents - 1) && made.allSatisfy { $0 == 11_994 },
            "each Command-F makes 11,994 crossfades: \(made.count) events, \(Set(made))")
        Self.expectFitsThreeFrames(crossfade, "crossfade")
    }
}
