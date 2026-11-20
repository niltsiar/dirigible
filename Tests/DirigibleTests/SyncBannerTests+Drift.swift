import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Decision 0077 D12: the drift lines of the result banner of Tools > Sync Clip to Track....
extension SyncBannerTests {
    func driftMoved(_ outcome: DriftOutcome, drift: SyncDrift = .spread(0)) -> SyncMoved {
        SyncMoved(
            lag: -163_200, peak: 0.98, drift: drift, headCut: 0, replaced: [], rate: 48_000, outcome: outcome)
    }

    static let first = "Moved the clip 3.4 s earlier. Match score: 0.98."

    func fix(splits: [DriftSplit] = []) -> DriftFix {
        DriftFix(
            slope: 100e-6, across: 2_880, worstResidual: 19.2, splits: splits, clips: ["C"], files: ["c drift"])
    }

    /// A fix gives the rate, the change across the clip, and the worst residual in place of the
    /// spread line, then one line for each cut. The time of a cut is a clip time, as the lag is.
    @Test func theBannerGivesTheDriftLine() {
        #expect(
            text(driftMoved(.corrected(fix()), drift: .spread(2_880)))
                == Self.first
                + " Corrected a drift of +100.0 ppm (60 ms across the clip) in one resample."
                + " The lag stays within 0.4 ms of the line.")
        let pause = DriftSplit(clipFrame: Frames(89_383_200), pause: 960_000)
        #expect(
            text(driftMoved(.corrected(fix(splits: [pause]))))
                == Self.first
                + " Corrected a drift of +100.0 ppm (60 ms across the clip) in one resample."
                + " The lag stays within 0.4 ms of the line."
                + " Split the clip at 31 min 2.2 s (the recording paused 20.0 s).")
        let slow = DriftFix(
            slope: -135e-6, across: -3_888, worstResidual: 0, splits: [], clips: ["C"], files: ["c drift"])
        #expect(text(driftMoved(.corrected(slow))).contains("Corrected a drift of -135.0 ppm (81 ms across the clip)"))
    }

    /// No fix gives "The drift was not corrected" with the cause, after the 0076 spread line.
    @Test func theBannerGivesTheCause() {
        let causes: [(DriftCause, String)] = [
            (.clipTooShort, "the clip is shorter than 5 min"),
            (.renderedFile, "the clip plays rendered audio: restore the original audio first"),
            (.takeFile, "a take records on the session clock"),
            (.noFit(.tooFewPoints), "too few parts of the clip match the reference"),
            (.noFit(.tooManyOutliers), "too few parts of the clip match the reference"),
            (.noFit(.twoLines), "the lag does not follow a steady line"),
            (.noFit(.endOutlier), "the lag does not follow a steady line"),
            (.noFit(.rateOutOfRange), "the clock rate is 1000 ppm or more from the reference"),
            (
                .composedRateOutOfRange,
                "the clip was fixed before, and both fixes together would change the clock by 1000 ppm or more"
            ),
            (.underOneMillisecond, "the lag changes by less than 1 ms across the clip"),
        ]
        for (cause, reason) in causes {
            #expect(
                text(driftMoved(.notCorrected(cause))) == Self.first + " The drift was not corrected: \(reason).",
                "\(cause)")
        }
        #expect(
            text(driftMoved(.notCorrected(.underOneMillisecond), drift: .spread(2_880)))
                == Self.first + " The lag changes by 60 ms across the clip."
                + " The drift was not corrected: the lag changes by less than 1 ms across the clip.",
            "the spread line stays before the cause")
    }
}
