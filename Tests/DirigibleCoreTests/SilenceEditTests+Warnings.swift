import Foundation
import Testing

@testable import DirigibleCore

/// The row warnings of a silence edit and a plan at scale (decision 0066, criteria C20, C30, C32).
extension SilenceEditTests {
    /// C20. A cut holds a word when it holds the anchor midpoint of the word, mapped to the timeline
    /// through the clip that plays it. On "host" (timeline frame = file frame) the midpoints
    /// 108 000, 130 000, 160 000, and 180 000 test both cut edges. On "guest", clip "G2" plays file
    /// frames 100 000 ..< 150 000 at 300 000: the word 90 000 ..< 110 000 has its anchor midpoint at
    /// 300 000 but shows as 300 000 ..< 310 000, whose midpoint is 305 000. Fail values: the midpoint
    /// of the shown range gives no warning for the last cut; a `<=` end test warns for 170 000 ..< 180 000.
    @Test mutating func aWordMidpointInTheCutIsAWarning() throws {
        try session.removeClips(["G"])
        try session.place(Clip(id: "G2", file: "g", start: 300_000, offset: 100_000, length: 50_000), on: "guest")
        session.addWords(
            [
                (1, 107_990..<108_010, "a"), (2, 129_990..<130_010, "b"), (3, 159_990..<160_010, "c"),
                (4, 179_990..<180_010, "d"),
            ],
            file: "h")
        session.addWords([(1, 90_000..<110_000, "e")], file: "g", transcript: 2)
        let first = try #require(SilencePlan.cut(of: 96_000..<132_000, keep: Self.keep))
        #expect(first == 108_000..<120_000, "the cut keeps 12 000 frames at each edge")
        let cuts = [first, 130_001..<140_000, 150_000..<160_001, 170_000..<180_000, 300_000..<302_000]
        let warnings = session.silenceEditWarnings(cuts: cuts, outside: nil, threshold: Gain(dB: -40)!)
        #expect(warnings == [[.word], [], [.word], [], [.word]])
    }

    /// C30. Outside windows over -40 dBFS warn for the cut that they meet. Silence 96 000 ..< 240 000
    /// has its cut 108 000 ..< 228 000 and a window at -39.9 dBFS at 120 000. Silence
    /// 264 000 ..< 312 000 has its cut 276 000 ..< 300 000 and a window at exactly -40.0 dBFS at
    /// 288 000. Silence 336 000 ..< 432 000 has a window at -39.9 dBFS at 336 000, in its kept
    /// start only. Fail value: a test of at or over the threshold warns for the second cut.
    @Test func soundOutsideTheScanInTheCutIsAWarning() throws {
        func meanSquare(_ dB: Double) -> Float { Float(pow(10, dB / 10)) }
        var levels = Array(repeating: WindowLevel(meanSquare: meanSquare(-60), peak: 0.01), count: 200)
        levels[50] = WindowLevel(meanSquare: meanSquare(-39.9), peak: 0.1)
        levels[120] = WindowLevel(meanSquare: meanSquare(-40), peak: 0.1)
        levels[140] = WindowLevel(meanSquare: meanSquare(-39.9), peak: 0.1)
        let outside = try #require(LevelSeries(range: 0..<480_000, window: 2_400, levels: levels))
        let silences: [Range<Frames>] = [96_000..<240_000, 264_000..<312_000, 336_000..<432_000]
        let cuts = try silences.map { try #require(SilencePlan.cut(of: $0, keep: Self.keep)) }
        #expect(cuts == [108_000..<228_000, 276_000..<300_000, 348_000..<420_000])
        let threshold = Gain(dB: -40)!
        #expect(
            session.silenceEditWarnings(cuts: cuts, outside: outside, threshold: threshold) == [
                [.soundOutsideScan], [], [],
            ])
        #expect(session.silenceEditWarnings(cuts: cuts, outside: nil, threshold: threshold) == [[], [], []])
    }

    /// C32 and U18. 1200 shortens of 48 000-frame silences, one each 96 000 frames, on 6 tracks with
    /// one clip each: one call cuts 24 000 frames from each silence. The test prints the time of the
    /// call for the slice row. The call takes seconds in a debug build, so it is a slow test.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aPlanOf1200ShortensOnSixTracksIsOneEdit() throws {
        let (count, period, length) = (1_200, 96_000, Frames(1_200 * 96_000))
        var session = Session(sampleRate: 48_000)
        for track in 0..<6 {
            let file = FileID("f\(track)")
            try session.addTrack(TrackID("t\(track)"), name: "t\(track)", layout: .mono)
            try session.addFile(AudioFile(id: file, path: "\(file).wav", layout: .mono, length: length))
            try session.place(
                Clip(id: ClipID("c\(track)"), file: file, start: 0, offset: 0, length: length), on: TrackID("t\(track)")
            )
        }
        let edits = (0..<count).map { index in
            SilenceEdit(range: Frames(index * period + 24_000)..<Frames(index * period + 72_000), action: .shorten)
        }
        let plan = try SilencePlan(edits, keep: Self.keep)
        let start = ContinuousClock.now
        let result = try session.editSilences(plan, muting: [])
        let elapsed = ContinuousClock.now - start
        print("U18: editSilences of \(count) shortens on 6 tracks took \(elapsed)")
        #expect(result.removed == Frames(count * 24_000) && result.cuts.count == count)
        #expect(session.end == length - Frames(count * 24_000), "the end moves left by the sum of the cuts")
        #expect(session.tracks.allSatisfy { $0.clips.count == count + 1 }, "each track has 1201 clips")
    }
}
