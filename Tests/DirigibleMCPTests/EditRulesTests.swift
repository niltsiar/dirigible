import DirigibleCore
import Testing

@testable import DirigibleMCP

/// The rules that a command and its tool share (decision 0041).
struct EditRulesTests {
    /// RR8. Each case of `rippleRanges`: the MCP tool cannot give `.missing`, so only this test
    /// pins it.
    @Test func rippleRangesGivesEachCase() {
        #expect(EditRules.rippleRanges(from: [], to: []) == .missing)
        #expect(EditRules.rippleRanges(from: [1], to: []) == .unpaired)
        #expect(EditRules.rippleRanges(from: [], to: [1]) == .unpaired)
        #expect(EditRules.rippleRanges(from: [0, 5], to: [3, 9, 12]) == .unpaired)
        #expect(EditRules.rippleRanges(from: [4], to: [3]) == .notIncreasing(range: 1))
        #expect(EditRules.rippleRanges(from: [0, 5], to: [3, 5]) == .notIncreasing(range: 2))
        #expect(EditRules.rippleRanges(from: [0, 5], to: [3, 9]) == .ranges([0..<3, 5..<9]))
    }
}
