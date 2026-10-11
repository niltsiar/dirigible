import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Track fader C9: the travel of the fader, its drag values, and the key steps.
struct FaderScaleTests {
    let travel = FaderScale(start: 0)

    @Test func theBreakPointsMapBothWays() {
        for (position, dB) in [(0.0, -60.0), (0.25, -20), (0.75, 0), (1, 20), (0.5, -10), (0.875, 10)] {
            #expect(abs(travel.position(dB: dB) - position) < 1e-12, "C9: \(dB) dB is at \(position)")
            #expect(abs(travel.rawDB(position: position) - dB) < 1e-12, "C9: \(position) is \(dB) dB")
        }
    }

    @Test func aDragValueRoundsAndSnapsToZero() {
        func at(_ dB: Double) -> Double { travel.dB(position: travel.position(dB: dB)) }
        #expect(at(3.2) == 3.0, "C9: 3.2 dB rounds to 3.0 dB")
        #expect(at(0.7) == 0 && at(-0.7) == 0, "C9: within 0.75 dB of 0 gives 0 dB")
        #expect(at(0.8) == 1.0 && at(-0.8) == -1.0, "C9: 0.8 dB rounds to 1.0 dB")
        #expect(travel.dB(position: -1) == -60 && travel.dB(position: 2) == 20, "the travel ends")
    }

    /// A stored value outside the travel pins the thumb; a drag from it keeps it at the end, so
    /// the first drag event does not jump.
    @Test func aStartOutsideTheTravelExtendsIt() {
        #expect(travel.position(dB: 30) == 1 && travel.position(dB: -80) == 0, "C9: the thumb pins")
        let loud = FaderScale(start: 30)
        #expect(loud.dB(position: 1) == 30, "C9: a drag from +30 dB starts at +30 dB")
        #expect(loud.dB(position: 0.75) == 0, "the rest of the travel stays")
        let quiet = FaderScale(start: -80)
        #expect(quiet.dB(position: 0) == -80, "C9: a drag from -80 dB starts at -80 dB")
        #expect(FaderScale(start: 30.3).dB(position: 1) == 30.3, "the rounding stays inside the extended end")
    }

    @Test func aKeyStepStopsAtTheTravelEnd() {
        #expect(FaderScale.step(0, by: 1) == 1 && FaderScale.step(-3.5, by: -1) == -4.5)
        #expect(
            FaderScale.step(19.5, by: 1) == 20 && FaderScale.step(-59.5, by: -1) == -60, "C12: a step stops at the end")
        #expect(FaderScale.step(30, by: 1) == 30, "C12: a stored +30 dB does not go up")
        #expect(FaderScale.step(30, by: -1) == 29, "C12: -1 dB from +30 dB gives +29 dB")
        #expect(FaderScale.step(-80, by: -1) == -80 && FaderScale.step(-80, by: 1) == -79)
    }
}
