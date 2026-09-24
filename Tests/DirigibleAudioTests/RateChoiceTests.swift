import Testing

@testable import DirigibleAudio

/// The rate rules of decision 0004 as a table (criterion 13).
struct RateChoiceTests {
    static func header(_ rate: Double, available: [ClosedRange<Double>]? = nil) -> CaptureHeader {
        var header = TakePackage.header(rate: rate)
        header.availableRates = available ?? [rate...rate]
        return header
    }

    /// Two checkpoints `seconds` apart on a clock at `rate`. With 1000 s, `rate` x 1000 is an
    /// integer for every rate here, so the fit is `rate` exactly.
    static func clock(_ rate: Double, seconds: Double = 1000) -> [Checkpoint] {
        [
            Checkpoint(fileFrame: 0, sampleTime: 0, hostTimeNanos: takeStart),
            Checkpoint(
                fileFrame: Int64((rate * seconds).rounded()), sampleTime: rate * seconds,
                hostTimeNanos: takeStart + UInt64(seconds * 1e9)),
        ]
    }

    /// (nominal, source, measured, driftCorrected)
    static func choose(_ header: CaptureHeader, _ checkpoints: [Checkpoint], frames: Int = 1000) -> (
        Double, Double, Double, Bool
    ) {
        let choice = RateChoice(header: header, checkpoints: checkpoints, frames: frames)
        return (choice.nominal, choice.source, choice.measured, choice.driftCorrected)
    }

    @Test func ruleOneUsesTheHeaderRate() {
        #expect(Self.choose(Self.header(24_000), Self.clock(24_000)) == (24_000, 24_000, 24_000, true))
    }

    @Test func ruleTwoSnapsToADiscreteAvailableRate() {
        let header = Self.header(48_000, available: [44_100...44_100, 48_000...48_000])
        #expect(Self.choose(header, Self.clock(44_100)) == (44_100, 44_100, 44_100, true))
    }

    @Test func ruleThreeDoesNotSnapToAContinuousRange() {
        let header = Self.header(48_000, available: [44_100...48_000])
        #expect(Self.choose(header, Self.clock(44_100)) == (48_000, 48_000, 44_100, false))
    }

    @Test(arguments: [48_048, 47_952])
    func aFitAt1000PPMIsRuleOne(fit: Double) {
        #expect(Self.choose(Self.header(48_000), Self.clock(fit)) == (48_000, 48_000, fit, true))
    }

    @Test(arguments: [48_048.048, 47_951.952])
    func aFitAt1001PPMIsRuleThree(fit: Double) {
        #expect(Self.choose(Self.header(48_000), Self.clock(fit)) == (48_000, 48_000, fit, false))
    }

    @Test func noUsableFitTakesTheHeaderRateWithAWarning() {
        let one = [Self.clock(48_000)[0]]
        let short = Self.clock(48_000, seconds: 0.4)
        let still = [Self.clock(48_000)[0], Checkpoint(fileFrame: 512, sampleTime: 512, hostTimeNanos: takeStart)]
        for checkpoints in [one, short, still] {
            #expect(Self.choose(Self.header(48_000), checkpoints) == (48_000, 48_000, 48_000, false))
        }
    }

    /// At 48002.4 Hz (50 ppm), 1 ms of drift at 48000 Hz is 960,048 frames.
    @Test func aDriftOver1MillisecondConvertsFromTheFit() {
        let clock = Self.clock(48_002.4)
        // 0.9 ms of drift.
        #expect(Self.choose(Self.header(48_000), clock, frames: 864_043) == (48_000, 48_000, 48_002.4, true))
        // 1.1 ms of drift.
        #expect(Self.choose(Self.header(48_000), clock, frames: 1_056_053) == (48_000, 48_002.4, 48_002.4, true))
    }
}
