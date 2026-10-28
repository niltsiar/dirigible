import Testing

@testable import DirigibleCore

/// The stored render values in Core, which the session reader parses (decision 0057 D10).
struct TreatmentTests {
    @Test func aKindRepeatsNoTreatment() throws {
        let twelve = Effect.noise(.standard)
        let six = Effect.noise(try #require(NoiseReduction(decibels: 6)))
        #expect(twelve.kind == .noise && six.kind == twelve.kind)
        #expect(Treatment([twelve, six]) == nil, "noise twice")
        #expect(Treatment([]) == nil)
        #expect(Treatment([six])?.effects == [six] && Treatment(twelve).effects == [twelve])
    }

    /// C17b: the chain order is hum, then noise, whatever the input order.
    @Test func humComesBeforeNoise() throws {
        let effects = try #require(Treatment([.noise(.standard), .hum(.hz50)])).effects
        #expect(effects == [.hum(.hz50), .noise(.standard)])
        #expect(Treatment([.hum(.hz50), .hum(.hz60)]) == nil, "hum twice")
        #expect(Hum(rawValue: 50) == .hz50 && Hum(rawValue: 60) == .hz60 && Hum(rawValue: 55) == nil)
    }
}
