import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Decision 0077 D12: the drift lines of the result banner of Tools > Sync Clip to Track....
extension SyncBannerTests {
    func driftMoved(_ outcome: DriftOutcome, drift: SyncDrift = .spread(0)) -> SyncMoved {
        SyncMoved(lag: -163_200, drift: drift, headCut: 0, replaced: [], rate: 48_000, outcome: outcome)
    }

    static let first = "Moved the clip 3.4 s earlier."

    func fix(splits: [DriftSplit] = []) -> DriftFix {
        let clips = [ClipID("C")] + splits.indices.map { ClipID("C-\($0 + 2)") }
        return DriftFix(
            slope: 100e-6, across: 2_880, worstResidual: 19.2, splits: splits, clips: clips,
            files: clips.map { _ in "c drift" })
    }

    /// A fix gives the change across the clip in place of the spread line, then one line for each
    /// cut. It names no rate, resample count, or residual. The time of a cut is a clip time, as the
    /// lag is.
    @Test func theBannerGivesTheDriftLine() {
        #expect(
            text(driftMoved(.corrected(fix()), drift: .spread(2_880)))
                == Self.first + " Corrected a drift of 60 ms across the clip.")
        let pause = DriftSplit(clipFrame: Frames(89_383_200), pause: 960_000)
        #expect(
            text(driftMoved(.corrected(fix(splits: [pause]))))
                == Self.first
                + " Corrected a drift of 60 ms across the clip."
                + " Split the clip at 31 min 2.2 s (the recording paused 20.0 s).")
        let slow = DriftFix(
            slope: -135e-6, across: -3_888, worstResidual: 0, splits: [], clips: ["C"], files: ["c drift"])
        #expect(text(driftMoved(.corrected(slow))).hasSuffix("Corrected a drift of 81 ms across the clip."))
    }

    /// No fix gives one row: the fact with its cause, or the fact and the step that removes the cause,
    /// after the 0076 spread line.
    @Test func theBannerGivesTheCause() {
        let restore = "The drift wasn't corrected. Restore the original audio of the clip, then sync again."
        let few = "Too few parts of the clip match the reference to correct the drift."
        let line = "The lag isn't steady enough to correct the drift."
        let causes: [(DriftCause, String)] = [
            (.clipTooShort, "The drift of a clip under 5 min isn't corrected."),
            (.renderedFile, restore),
            (.takeFile, "The drift of a take isn't corrected."),
            (.transcriptNotLoaded, "The drift wasn't corrected. Import the transcript again, then sync again."),
            (.noFit(.tooFewPoints), few),
            (.noFit(.tooManyOutliers), few),
            (.noFit(.twoLines), line),
            (.noFit(.endOutlier), line),
            (.noFit(.rateOutOfRange), "The clock rate differs too much from the reference to correct the drift."),
            (.composedRateOutOfRange, "A second drift fix would change the clock of this clip too much."),
            (.underOneMillisecond, "A drift under 1 ms across the clip isn't corrected."),
        ]
        for (cause, reason) in causes {
            #expect(text(driftMoved(.notCorrected(cause))) == Self.first + " \(reason)", "\(cause)")
        }
        #expect(
            text(driftMoved(.notCorrected(.underOneMillisecond), drift: .spread(2_880)))
                == Self.first + " The lag changes by 60 ms across the clip."
                + " A drift under 1 ms across the clip isn't corrected.",
            "the spread line stays before the cause")
    }
}
