import Foundation
import Testing

@testable import DirigibleCore

/// The mute rows of one silence edit (decision 0066, criterion C32).
extension SilenceEditTests {
    /// Many mute rows give the envelope of one `changeGain` for each row, also for rows in any order,
    /// rows that touch, a row of 2 ramps and a few frames, and an envelope that is not flat. A gain
    /// is compared to 1e-9 dB: a point on a line has no exact float value.
    @Test mutating func manyMuteRowsEqualOneChangeGainForEachRow() throws {
        let base = [(40_000, -3.0), (150_000, 2.0), (300_000, -8.0), (330_500, -1.0)].map {
            GainEnvelope.Point(frame: Frames($0.0), gain: Gain(dB: $0.1)!)
        }
        try session.setEnvelopes(["H": try #require(GainEnvelope(base))])
        let rows: [Range<Frames>] = [264_000..<312_000, 96_000..<240_000, 330_000..<331_000, 312_000..<325_000]
        var expected = session
        let (ramp, floor) = (session.silenceRamp, Gain(dB: Gain.range.lowerBound)!)
        for row in rows.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let range = (row.lowerBound + ramp)..<(row.upperBound - ramp)
            try expected.changeGain(by: floor, in: range, on: ["host", "guest"], ramp: ramp)
        }

        let plan = try Self.plan(rows.map { ($0, .mute) })
        let result = try session.editSilences(plan, muting: ["host", "guest"])

        #expect(result.skipped.isEmpty)
        for clip in ["H", "G"] as [ClipID] {
            let got = try #require(session.clip(clip)?.clip.envelope)
            let want = try #require(expected.clip(clip)?.clip.envelope)
            #expect(got.points.map(\.frame) == want.points.map(\.frame), "\(clip): the point frames")
            let drift = zip(got.points, want.points).map { abs($0.gain.dB - $1.gain.dB) }.max() ?? 0
            #expect(drift < 1e-9, "\(clip): the largest gain difference is \(drift) dB")
        }
        let host = try #require(session.clip("H")?.clip.envelope)
        #expect(host.gain(at: 150_000) < -90 && host.gain(at: 288_000) < -90, "the rows are muted")
    }
}
