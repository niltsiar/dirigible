import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The Command-F benches of the 2 h fixture (decisions 0035 and 0036): the fades of every clip,
/// and the crossfades of every join.
extension MouseEventBenchmark {
    /// The fixture with no fades and a gap of 1 frame before each clip but the first of a track, so
    /// no clip touches a neighbor: Command-F on Select All fades every clip and makes no crossfade
    /// (no butt join, decisions 0035 and 0036).
    static func gappedFixture() throws -> Session {
        var (session, _) = try fixture()
        try session.setFades(
            Dictionary(uniqueKeysWithValues: session.tracks.flatMap { $0.clips.map { ($0.id, Fades.zero) } }))
        for track in session.tracks.map(\.id) {
            for n in 1..<2000 {
                let frame = Frames(n * frames / 2000)
                try session.clear(frame..<frame + 1, on: track)
            }
        }
        return session
    }

    /// Fades C26: Command-F on Select All at 2 h (12,000 clips with no fade and no butt join before
    /// each event): the edit, `changedFrames`, the SwiftUI update, and the draw. The draw after a
    /// change of every clip takes about 28 ms on the Intel Mac, so the rule is a pair rule
    /// (decisions.tsv). The p50 is not more than the p50 of a Select All Nudge, a whole-session
    /// edit that main has, in the same harness and run. The max is not more than 1.25 times the
    /// nudge max. Each event must fade every clip.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aCommandFOnSelectAllCostsNoMoreThanANudge() async throws {
        let nudge = try await NavigationKeyBenchmark.measure("nudge", budget: 100_000) { model, n in
            if let studio = model.studio { model.timeline.marks = Marks.all(in: studio.session) }
            return { model.run(n % 2 == 0 ? .nudgeRight : .nudgeLeft) }
        }
        let gapped = try Self.gappedFixture()
        let standard = try #require(Fades(fadeIn: 24_000, fadeOut: 24_000))
        var faded: [Int] = []
        let fade = try await NavigationKeyBenchmark.measure("fade", budget: 100_000) { model, event in
            if let studio = model.studio {
                // The count of the last event, before the reset.
                if event > 0 {
                    faded.append(studio.session.tracks.reduce(0) { $0 + $1.clips.count { $0.fades == standard } })
                }
                try? studio.edit { s throws(SessionError) in s = gapped }
                model.timeline.marks = Marks.all(in: studio.session)
            }
            return { model.run(.fade) }
        }
        #expect(
            faded.count == 48 && faded.allSatisfy { $0 == 12_000 }, "each Command-F fades 12,000 clips: \(Set(faded))")
        try Self.expectLikeANudge(fade, nudge, "fade")
    }

    /// The pair rule of the Command-F benches: per zoom, the p50 is not more than `p50Budget` of
    /// the nudge p50, and the max is not more than 1.25 times the nudge max.
    static func expectLikeANudge(
        _ command: [(p50: Duration, max: Duration)], _ nudge: [(p50: Duration, max: Duration)], _ name: String,
        p50Factor: Double = 1, p50Under: Duration? = nil
    ) throws {
        try #require(command.count == zooms.count && nudge.count == zooms.count)
        for (index, (zoom, _)) in zooms.enumerated() {
            let (command, nudge) = (command[index], nudge[index])
            let budget = p50Budget(nudge: nudge.p50, factor: p50Factor, under: p50Under)
            expectWithinBudget(command.p50, budget, "\(name) p50 \(zoom): \(command.p50), budget \(budget)")
            // The max is one sample of 24. In the 11b-1 bench pairs it missed by up to 16 %, also in A/A runs.
            expectWithinBudget(
                command.max, nudge.max * 1.25, "\(name) max \(zoom): \(command.max), 1.25 x nudge \(nudge.max)")
        }
    }

    /// The p50 budget of a Command-F bench: `factor` x the nudge p50, and under `under` when it is
    /// given (1 ns less, so a p50 at `under` misses).
    static func p50Budget(nudge: Duration, factor: Double, under: Duration?) -> Duration {
        let pair = nudge * factor
        guard let under else { return pair }
        return min(pair, under - .nanoseconds(1))
    }

    /// The B2 rule of run 11c-2 (decisions.tsv, criterion change): 1.25 x the nudge p50 and under
    /// 50 ms. Fail values: 1.3 x the nudge p50, and 50 ms with a slow nudge.
    @Test func theJoinsBudgetIsAPairRuleUnderFiftyMilliseconds() {
        func passes(_ p50: Duration, nudge: Duration) -> Bool {
            p50 <= Self.p50Budget(nudge: nudge, factor: 1.25, under: .milliseconds(50))
        }
        let nudge = Duration.milliseconds(38)
        #expect(passes(nudge * 1.2, nudge: nudge) && !passes(nudge * 1.3, nudge: nudge))
        #expect(passes(.milliseconds(49), nudge: .milliseconds(45)), "1.25 x 45 ms is over the ceiling")
        #expect(!passes(.milliseconds(50), nudge: .milliseconds(45)), "50 ms is not under 50 ms")
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

    /// B2 (run 11c-2): Command-F on Select All of `joinedFixture` (decision 0036): 11,994
    /// crossfades and the fades of the 12 free edges, `changedFrames`, the SwiftUI update, and the
    /// draw. The p50 is not more than 1.25 x the nudge p50 and under 50 ms (criterion change of
    /// run 11c-2: two edit passes over 12,000 clips), and the max keeps the rule of
    /// `expectLikeANudge`. Each event must make every crossfade.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aCommandFOnJoinsCostsNoMoreThanANudge() async throws {
        let nudge = try await NavigationKeyBenchmark.measure("nudge", budget: 100_000) { model, n in
            if let studio = model.studio { model.timeline.marks = Marks.all(in: studio.session) }
            return { model.run(n % 2 == 0 ? .nudgeRight : .nudgeLeft) }
        }
        let joined = try Self.joinedFixture()
        #expect(joined.tracks.allSatisfy { $0.clips.count == 2000 && $0.clips.last?.end == Frames(Self.frames) })
        var made: [Int] = []
        let crossfade = try await NavigationKeyBenchmark.measure("crossfade", budget: 100_000) { model, event in
            if let studio = model.studio {
                // The count of the last event, before the reset.
                if event > 0 {
                    made.append(studio.session.tracks.reduce(0) { $0 + $1.clips.count { $0.crossfades.end != .zero } })
                }
                try? studio.edit { s throws(SessionError) in s = joined }
                model.timeline.marks = Marks.all(in: studio.session)
            }
            return { model.run(.fade) }
        }
        #expect(
            made.count == 48 && made.allSatisfy { $0 == 11_994 }, "each Command-F makes 11,994 crossfades: \(Set(made))"
        )
        try Self.expectLikeANudge(crossfade, nudge, "crossfade", p50Factor: 1.25, p50Under: .milliseconds(50))
    }
}
