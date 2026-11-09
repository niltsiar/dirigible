import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The level ride rules of a measure group with no reference, on step arrays with no audio.
extension LevelRideTests {
    /// A group with no block over the gates gives no curve and no ride layer.
    @Test func silenceGivesNoCurve() {
        let silent = rideSteps([(100, -80)])
        #expect(LevelRide.standard.gains(silent) == nil)
        #expect(rideLayer(stepMeanSquares: silent, envelopeDB: Array(repeating: 0, count: 100)) == nil)
        #expect(LevelRide.standard.gains(rideSteps([(100, -20)])) != nil, "control")
    }

    /// A non-finite sample empties the steps of the meter, so no gain comes from it.
    @Test func nonFiniteStepsGiveNoCurve() throws {
        var meter = try #require(LoudnessMeter(sampleRate: 48_000, layout: .mono, keepsSteps: true))
        meter.feed(try pcmBuffer([sine(seconds: 2, rate: 48_000).map { $0 * 0.1 }]))
        #expect(LevelRide.standard.gains(try #require(meter.stepMeanSquares)) != nil, "control")
        meter.feed(try pcmBuffer([[.nan] + [Float](repeating: 0.1, count: 47_999)]))
        #expect(LevelRide.standard.gains(try #require(meter.stepMeanSquares)) == nil)
    }

    /// An empty step array, and a group under one 400 ms block, give no curve, not a trap.
    @Test func noStepsGiveNoCurve() {
        #expect(LevelRide.standard.gains([]) == nil)
        #expect(rideLayer(stepMeanSquares: [], envelopeDB: []) == nil)
        #expect(LevelRide.standard.gains(rideSteps([(3, -20)])) == nil)
        #expect(LevelRide.standard.gains(rideSteps([(4, -20)])) != nil, "control: one block")
    }
}
