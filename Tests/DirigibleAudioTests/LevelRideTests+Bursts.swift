import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// 10 s at -20 LUFS, a 3 s pause, a burst of `burst` steps at -32 LUFS (12 LU under, speech), a
/// 3 s pause, and 10 s at -20 LUFS. The burst starts at step 130.
func burstBetweenPauses(_ burst: Int) -> [Double] {
    rideSteps([(100, -20), (30, -50), (burst, -32), (30, -50), (100, -20)])
}

/// The largest final gain of a pause step minus the final gain of the last speech step before it.
func pauseOverLastSpeech(_ steps: [Double], _ gains: [Double]) throws -> Double {
    let gate = Loudness.meanSquare(try #require(riddenLoudness(steps)) - 15)
    var (last, highest): (Double?, Double) = (nil, -.infinity)
    for step in steps.indices {
        if steps[step] >= gate {
            last = gains[step]
        } else if let last {
            highest = max(highest, gains[step] - last)
        }
    }
    return highest
}

/// The pause hold on short sounds between pauses, on step arrays with no audio.
extension LevelRideTests {
    /// A burst of 1 or 2 steps rides as speech, diluted by the held pause gains around it to
    /// 6 x steps / 11 dB over the pause, and the pause after it keeps the gain of the pause before.
    @Test(arguments: [1, 2])
    func shortBurstKeepsThePauseGain(burst: Int) throws {
        let gains = try ride(burstBetweenPauses(burst))
        let before = gains[118]
        let after = gains[130 + burst + 12]
        #expect(abs(after - before) <= 0.1, "pause after \(after) dB, before \(before) dB")
        for step in 130..<130 + burst {
            let lift = gains[step] - before
            #expect(abs(lift - 6 * Double(burst) / 11) <= 0.1, "burst step \(step): \(lift) dB over the pause")
        }
    }

    /// A run of 3 speech steps moves the held gain; the pause after it gets the smoothed gain of
    /// the last run step plus 0.5 dB: +4.47 + 0.5, 4.91 dB over the pause before, not the +6 of
    /// its raw gain.
    @Test func runOfThreeStepsMovesThePauseGain() throws {
        let gains = try ride(burstBetweenPauses(3))
        let rise = gains[145] - gains[118]
        #expect(abs(rise - 4.91) <= 0.1, "the pause after the run rises by \(rise) dB, not 4.91")
    }

    /// No pause step gets more than the final gain of the last speech step before it plus 0.5 dB,
    /// also after a burst of 1 to 3 steps.
    @Test(arguments: [1, 2, 3])
    func noPauseStepGetsMoreThanTheLastSpeechStep(burst: Int) throws {
        let steps = burstBetweenPauses(burst)
        let over = try pauseOverLastSpeech(steps, try ride(steps))
        #expect(over <= 0.5 + 1e-9, "a pause step gets \(over) dB over the last speech step")
    }

    /// After a loud 100 ms burst in a lifted passage, the pause gets the final gain of the burst
    /// plus 0.5 dB (-5.90 + 0.5 on paper), not the held gain +4.81 of the passage before it.
    @Test func pauseAfterALoudBurstStaysNearTheBurstGain() throws {
        let steps = rideSteps([(100, -20), (100, -26), (30, -50), (1, -14), (30, -50), (100, -20)])
        let gains = try ride(steps)
        #expect(abs(gains[243] - gains[230] - 0.5) <= 0.01, "pause \(gains[243]) dB, burst \(gains[230]) dB")
        #expect(try pauseOverLastSpeech(steps, gains) <= 0.5 + 1e-9)
    }
}
