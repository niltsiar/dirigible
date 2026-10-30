import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// The level rule of a de-clip that fills no run (decision 0064 D4).
extension EffectRenderTests {
    /// C7: a de-clip that fills no run keeps the 0054 gain rule: the clip gain gives s1 x s2 back,
    /// and the drop is 0. With the rumble, the 20 Hz square of 0.99 (plateaus over 10 ms, so no
    /// clipped run) overshoots in the high-pass, so s1 < 1; with a gain of 1.5 after the chain, a
    /// 440 Hz sine of 0.9 gets a second pass, and its clip gain is 20 log10(1.35) dB to 0.05 dB.
    /// Fail: 0 dB of added gain for each run with a de-clip.
    @Test func declipWithNoRunGivesTheLevelBack() throws {
        let fixture = try RenderFixture()
        let square: [Float] = (0..<48_000).map { ($0 / 1_200) % 2 == 0 ? 0.99 : -0.99 }
        let sine: [Float] = (0..<48_000).map { frame in
            let phase = 2 * Double.pi * 440 * Double(frame) / 48_000
            return Float(0.9 * sin(phase))
        }
        try fixture.add("f1", [square], track: "t1", clips: [("c1", 0, square.count)])
        try fixture.add("f2", [sine], track: "t2", clips: [("c2", 0, sine.count)])
        let rumble = try #require(Treatment([.declip(.standard), .rumble(.standard)]))

        let first = try repair(fixture, ["c1"], rumble)
        let second = try repair(fixture, ["c2"], Treatment(.declip(.standard)), addedStage: TestStage(gain: 1.5))

        var gains: [Double] = []
        for (outcome, clip) in [(first, ClipID("c1")), (second, "c2")] {
            let report = try #require(outcome.repairs[clip])
            gains.append(try #require(outcome.session.clip(clip)?.clip.gain.dB))
            #expect(report.runs == 0 && report.levelDrop == 0, "\(clip): \(report)")
        }
        #expect(gains[0] > 3, "c1: the clip gain gives the level back: \(gains[0]) dB")
        #expect(abs(gains[1] - 20 * log10(1.35)) < 0.05, "c2: the clip gain gives s2 back: \(gains[1]) dB")
    }
}
