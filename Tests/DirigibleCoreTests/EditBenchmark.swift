import DirigibleCore
import Foundation
import Testing

/// Compares a time with its budget. With -O (`make bench`), a miss fails the test. In debug, the
/// budget is a proxy that the load of the suite moves, so a miss only prints a report line.
func expectWithinBudget(
    _ value: Duration, _ budget: Duration, _ message: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    #if DEBUG
        if value > budget { print("bench report: \(message) over debug budget \(budget)") }
    #else
        #expect(value <= budget, "\(message)", sourceLocation: sourceLocation)
    #endif
}

/// Edit-commands criterion 8: at 2 h, 6 tracks, and 2 000 clips per track (a 3.5 s clip each 3.6 s),
/// each bulk edit runs as one `History.edit` with a p95 of 16 ms or less in an optimized build
/// (`make bench FILTER=EditBenchmark`). `make test-slow` runs it unoptimized with a budget of
/// 200 ms, a proxy only. A paste through a `place` loop took 12.6 s in the probe.
struct EditBenchmark {
    #if DEBUG
        static let budget = Duration.milliseconds(200)
    #else
        static let budget = Duration.milliseconds(16)
    #endif
    /// Silence-tool C32: an Apply is one click, so its budget is 3 frames at 60 Hz, a time that a
    /// user feels (`performance-criteria.md`). The debug value is a proxy, as `budget`.
    #if DEBUG
        static let applyBudget = budget
    #else
        static let applyBudget = Duration.milliseconds(50)
    #endif

    static let hour = Frames(172_800_000)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func eachEditOfTwoHoursFitsOneFrame() throws {
        let history = History(try Self.session())
        let tracks = history.session.tracks.map(\.id)
        let excerpt = try history.session.excerpt(of: .zero..<Self.hour, on: tracks)
        let firstHour = history.session.tracks.flatMap { $0.clips.prefix(1_000).map(\.id) }
        #expect(excerpt.lanes.allSatisfy { $0.clips.count == 1_000 } && firstHour.count == 6_000)
        // Fades C5: Command-F on Select All sets the fades of every clip in one batch.
        let fades = Fades(fadeIn: 24_000, fadeOut: 24_000)!
        let allFades = Dictionary(
            uniqueKeysWithValues: history.session.tracks.flatMap { $0.clips.map { ($0.id, fades) } })
        #expect(allFades.count == 12_000)
        let allGains = allFades.mapValues { _ in Gain(dB: -6)! }

        let edits: [(String, (inout Session) throws -> Void)] = [
            ("paste of 1,000 clips on 6 tracks", { try $0.paste(excerpt, at: Self.hour, on: tracks) }),
            ("splitClips at 2 frames on 6 tracks", { try $0.splitClips(at: [100_000_000, 200_000_000], on: tracks) }),
            (
                "clear of 1 h on 6 tracks",
                { session in
                    for track in tracks { try session.clear(Self.hour..<(Self.hour + Self.hour), on: [track]) }
                }
            ),
            ("nudge of 1,000 clips on 6 tracks", { try $0.nudge(firstHour, by: 480) }),
            ("setFades of 12,000 clips", { try $0.setFades(allFades) }),
            ("setGains of 12,000 clips", { try $0.setGains(allGains) }),
            // Clip-set-clipboard C1b: Copy and Paste of a clip set of the first hour.
            (
                "excerpt and set paste of 6,000 clips",
                { try $0.paste(try $0.excerpt(of: firstHour), at: Self.hour, on: tracks) }
            ),
        ]
        for (name, edit) in edits { try Self.measure(name, history, edit) }

        // Ripple C14b (decision 0037): 100 markers, and each later clip on 6 tracks moves.
        var marked = history.session
        for n in 0..<100 {
            try marked.setMarker(
                Marker(id: MarkerID("m\(n)"), name: "M", position: Frames(n * 3_456_000), kind: .marker))
        }
        let ripples: [(String, (inout Session) throws -> Void)] = [
            ("rippleDelete near the start on 6 tracks", { try $0.rippleDelete(100_000..<200_000, on: tracks) }),
            ("rippleInsert near the start on 6 tracks", { try $0.rippleInsert(48_000, at: 100_000, on: tracks) }),
            (
                "rippleTrim of the first clip on 6 tracks",
                { try $0.rippleTrim("c0", edge: .end, by: -4_800, on: tracks) }
            ),
        ]
        for (name, edit) in ripples { try Self.measure(name, History(marked), edit) }
    }

    static let silenceCount = 1_200
    static let silencePeriod = 96_000

    /// Six mono tracks with one clip each, as long as 1200 silence periods of 96 000 frames.
    static func silenceSession() throws -> Session {
        var session = Session(sampleRate: 48_000)
        let length = Frames(silenceCount * silencePeriod)
        for n in 1...6 {
            let file = FileID("f\(n)")
            try session.addFile(AudioFile(id: file, path: "f\(n).wav", layout: .mono, length: length))
            try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono)
            try session.place(
                Clip(id: ClipID("c\(n)"), file: file, start: 0, offset: 0, length: length), on: TrackID("t\(n)"))
        }
        return session
    }

    /// The silence of period `n`: 24 000 ..< 72 000 frames into it.
    static func silenceEdits(_ action: SilenceEdit.Action) -> [SilenceEdit] {
        (0..<silenceCount).map {
            SilenceEdit(
                range: Frames($0 * silencePeriod + 24_000)..<Frames($0 * silencePeriod + 72_000), action: action)
        }
    }

    /// Silence-tool C32: one `editSilences` of 1200 shortens on 6 tracks with one clip each, so each
    /// lane gets 1201 clips.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aSilencePlanOf1200ShortensFitsItsBudget() throws {
        let plan = try SilencePlan(Self.silenceEdits(.shorten), keep: 24_000)
        try Self.measure(
            "editSilences of 1,200 shortens on 6 tracks", History(try Self.silenceSession()), within: Self.applyBudget
        ) {
            _ = try $0.editSilences(plan, muting: [])
        }
    }

    /// Silence-tool C32: one `editSilences` of 1200 mutes on the 6 tracks. Each mute adds its
    /// ramp points to the envelope of the one clip of each track.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aSilencePlanOf1200MutesFitsItsBudget() throws {
        let session = try Self.silenceSession()
        let plan = try SilencePlan(Self.silenceEdits(.mute), keep: nil)
        let tracks = session.tracks.map(\.id)
        try Self.measure("editSilences of 1,200 mutes on 6 tracks", History(session), within: Self.applyBudget) {
            _ = try $0.editSilences(plan, muting: tracks)
        }
    }

    /// Runs `edit` 20 times on a copy of `history`, and compares the p95 with the budget.
    static func measure(
        _ name: String, _ history: History, within budget: Duration = EditBenchmark.budget,
        _ edit: (inout Session) throws -> Void
    ) throws {
        var times: [Duration] = []
        for _ in 0..<20 {
            var copy = history
            let start = ContinuousClock.now
            try copy.edit(edit)
            times.append(ContinuousClock.now - start)
            #expect(copy.canUndo)
        }
        let p95 = times.sorted()[18]
        print("EditBenchmark \(name): p95 \(p95)")
        expectWithinBudget(p95, budget, "\(name): p95 \(p95)")
    }

    /// Places 2 000 clips on the first track, then pastes that track onto the other five.
    static func session() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: hour + hour))
        for n in 1...6 { try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono) }
        for n in 0..<2_000 {
            let start = Frames(n * 172_800)
            try session.place(
                Clip(id: ClipID("c\(n)"), file: "f", start: start, offset: start, length: 168_000), on: "t1")
        }
        let first = try session.excerpt(of: .zero..<(hour + hour), on: Array(repeating: "t1", count: 5))
        try session.paste(first, at: .zero, on: ["t2", "t3", "t4", "t5", "t6"])
        return session
    }
}
