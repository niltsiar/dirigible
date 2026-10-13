import Testing

@testable import DirigibleMCP

/// C3: the gate passes a growth of 1 or more at once, any growth 10 s after the last pass, and
/// never an equal or a lower value (decision 0049).
struct ProgressGateTests {
    @Test func theGatePassesAGrowthOfOneOrAGrowthAfterTenSeconds() {
        let start = ContinuousClock.now
        var gate = ProgressGate()
        #expect(gate.pass(0.25, at: start) == 25, "the first value passes")
        #expect(gate.pass(0.26, at: start) == 26, "a growth of 1.0 passes at once")
        #expect(gate.pass(0.269, at: start + .seconds(9)) == nil, "a growth of 0.9 at 9 s does not pass")
        #expect(gate.pass(0.261, at: start + .seconds(10)) == 26.1, "a growth of 0.1 at 10 s passes")
        #expect(gate.pass(0.261, at: start + .seconds(30)) == nil, "an equal value never passes")
        #expect(gate.pass(0.2, at: start + .seconds(40)) == nil, "a lower value never passes")
        #expect(gate.pass(1, at: start + .seconds(50)) == nil, "100 never passes: the answer follows")
        #expect(gate.pass(0.5, at: start + .seconds(50)) == 50)
    }
}
