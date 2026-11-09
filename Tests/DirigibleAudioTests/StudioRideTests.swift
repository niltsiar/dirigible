import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Level Over Time through `Studio.levelOverTime` (run 2026-10-14-leveler, the envelope ride): the
/// composition cases C25 to C27 on the probe U1r-b fixtures, and the job rules C6, C10 to C12b.
@MainActor
struct StudioRideTests {
    /// C25: a manual +6 dB lift on a quiet passage (fixture A) is not lifted twice. Passage at
    /// -6 dB: the heard gain at 27.5 s is 6.5 dB or less. Passage at -10 dB: the heard passage and
    /// the loud part are 1 LU or less apart. Also with a whole-clip gain of -6 dB after the lift.
    @Test(arguments: [(-6.0, 0.0), (-10.0, 0.0), (-6.0, -6.0), (-10.0, -6.0)])
    func manualLiftIsNotLiftedTwice(passage: Double, whole: Double) async throws {
        let samples = rideSpeech(seconds: 60) { (20..<35).contains($0) ? passage : 0 }
        let fixture = try await RideFixture(samples) { session in
            try session.changeGain(by: Gain(dB: 6)!, in: 960_000..<1_680_000, on: ["t1"], ramp: session.gainRamp)
            if whole != 0 {
                try session.changeGain(
                    by: Gain(dB: whole)!, in: 0..<Frames(samples.count), on: ["t1"], ramp: session.gainRamp)
            }
        }
        let report = try await fixture.ride()
        let clip = try fixture.clip()
        let gain = clip.layerGain(at: stepCentre(275)) - whole
        let (loud, quiet) = (try heardLoudness(samples, clip, 5, 15), try heardLoudness(samples, clip, 22, 33))
        let numbers = "passage \(passage), whole \(whole): heard gain \(gain), loud \(loud), passage \(quiet)"
        #expect(report.leveled == ["c1"] && !clip.ride.isEmpty, "\(report)")
        if passage == -6 {
            #expect(gain <= 6.5, "\(numbers)")
        } else {
            #expect(abs(loud - quiet) <= 1, "\(numbers)")
        }
    }

    /// C26: a manual -6 dB cut on a loud passage (+6 dB) is not cut twice: the heard gain at 27.5 s
    /// is -6.5 dB or more.
    @Test func manualCutIsNotCutTwice() async throws {
        let samples = rideSpeech(seconds: 60) { (20..<35).contains($0) ? 6 : 0 }
        let fixture = try await RideFixture(samples) { session in
            try session.changeGain(by: Gain(dB: -6)!, in: 960_000..<1_680_000, on: ["t1"], ramp: session.gainRamp)
        }
        try await fixture.ride()
        let clip = try fixture.clip()
        let (gain, b) = (clip.layerGain(at: stepCentre(275)), try sourceRide(samples).dB[275])
        #expect(gain >= -6.5, "heard gain \(gain), ride \(clip.ride.gain(at: stepCentre(275))), b \(b)")
    }

    /// C27: a duck dip (fixture B, music -3 +/- 3 dB, runs 20..40 s and 55..70 s) keeps its depth.
    /// In the dip the ride is at most max(0, b) + 0.1 dB, b the ride of the source alone; the
    /// envelope stays; at 5..15 s the heard music is within 0.1 dB of the ride of the source alone,
    /// with a -16 and a -5 dB duck, also with a whole-clip gain of -3 dB after the duck.
    @Test(arguments: [(-16.0, 0.0), (-5.0, 0.0), (-16.0, -3.0), (-5.0, -3.0)])
    func duckDipKeepsItsDepth(depth: Double, whole: Double) async throws {
        let samples = rideMusic(seconds: 90) { -3 + 3 * sin(2 * .pi * $0 / 8) }
        let defaults = DuckShape.defaults(sampleRate: 48_000)
        let shape = DuckShape(
            depth: Gain(dB: depth)!, attack: defaults.attack, release: defaults.release, threshold: defaults.threshold,
            hold: defaults.hold)
        let fixture = try await RideFixture(samples) { session in
            try session.duck(
                runs: [960_000..<1_920_000, 2_640_000..<3_360_000], shape: shape, music: ["t1"], scope: nil)
            if whole != 0 {
                try session.changeGain(
                    by: Gain(dB: whole)!, in: 0..<Frames(samples.count), on: ["t1"], ramp: session.gainRamp)
            }
        }
        let envelope = try fixture.clip().envelope
        try await fixture.ride()
        let clip = try fixture.clip()
        let source = try sourceRide(samples)
        let over = (205..<395).map { clip.ride.gain(at: stepCentre($0)) - max(0, source.dB[$0]) }.max()!
        let heard = try heardLoudness(samples, clip, 5, 15)
        let alone = heardLoudness(try heardSteps(samples) { whole + source.layer.gain(at: $0) }, 5, 15)
        let numbers = "depth \(depth), whole \(whole): dip ride - max(0, b) \(over), heard \(heard), alone \(alone)"
        #expect(over <= 0.1, "\(numbers)")
        #expect(clip.envelope == envelope, "the ride changed the envelope")
        #expect(abs(heard - alone) <= 0.1, "\(numbers)")
    }

    /// C7c: a split speech clip with a duck across the cut, or a manual point on one part, is one
    /// measure group: after a ride both parts hold one list, so the ride does not step at the cut.
    @Test(arguments: [false, true])
    func duckAcrossTheCutHasNoRideStep(pointOnOnePart: Bool) async throws {
        let samples = rideSpeech(seconds: 40) { (12..<28).contains($0) ? -10 : 0 }
        let fixture = try await RideFixture(samples) { session in
            _ = try session.split("c1", at: 960_000, rightID: "c2")
            if pointOnOnePart {
                try session.setEnvelope([480_000: Gain(dB: -6)!], clip: "c1")
            } else {
                try session.duck(
                    runs: [840_000..<1_080_000], shape: .defaults(sampleRate: 48_000), music: ["t1"], scope: nil)
            }
        }
        let report = try await fixture.ride(["c1", "c2"])
        let (left, right) = (try fixture.clip("c1"), try fixture.clip("c2"))
        #expect(report.leveled == ["c1", "c2"] && !left.ride.isEmpty, "\(report)")
        #expect(left.ride == right.ride, "two lists on one split clip")
        let step = abs(left.ride.gain(at: 959_999) - right.ride.gain(at: 960_000))
        #expect(step <= 0.1, "ride step at the cut \(step)")
    }

    /// C7c, the accepted limit: a ride of part A of a split clip measures A and B and writes A
    /// only. A gets the list of a ride of both parts, and B keeps its old ride, so the ride steps
    /// at the cut by the list of A there minus the old list of B there.
    @Test func rideOfOnePartOfASplitClip() async throws {
        let samples = rideSpeech(seconds: 40) { (12..<28).contains($0) ? -10 : 0 }
        let old = GainEnvelope([.init(frame: 240_000, gain: Gain(dB: 2)!)])!
        let fixture = try await RideFixture(samples) { session in
            _ = try session.split("c1", at: 960_000, rightID: "c2")
            try session.setRides(["c1": old, "c2": old])
        }
        let report = try await fixture.ride(["c1"])
        let (one, other) = (try fixture.clip("c1").ride, try fixture.clip("c2").ride)
        #expect(report.leveled == ["c1"] && other == old, "\(report)")
        try fixture.studio.undo()
        try await fixture.ride(["c1", "c2"])
        let both = try fixture.clip("c1").ride
        #expect(one == both, "a ride of A alone measured A alone")
        let step = one.gain(at: 960_000) - old.gain(at: 960_000)
        #expect(abs(step) > 0.1, "the pinned step at the cut is \(step)")
    }

    /// The report gives the largest ride gain that the leveled clips play, not a gain of the
    /// shared list that only the part that is not leveled plays.
    @Test func largestGainIsOfTheLeveledWindow() async throws {
        let samples = rideSpeech(seconds: 30) { $0 < 15 ? 0 : -12 }
        let fixture = try await RideFixture(samples) { session in
            _ = try session.split("c1", at: 720_000, rightID: "c2")
        }
        let report = try await fixture.ride(["c1"])
        let ride = try fixture.clip("c1").ride
        let played = stride(from: 0, to: 720_000, by: 48).map { ride.gain(at: Frames($0)) }
        let expected = try #require(played.max { abs($0) < abs($1) })
        let listed = try #require(ride.points.map(\.gain.dB).max { abs($0) < abs($1) })
        #expect(abs(listed) > abs(expected) + 1, "the fixture has no louder gain past the window: \(listed)")
        let largest = try #require(report.largestGain).dB
        #expect(abs(largest - expected) <= 0.05, "largest \(largest), the window plays up to \(expected)")
    }
}
