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

    /// The exact bounds of an import range, 0...2^40 and 1...2^40.
    @Test func importRangeHoldsItsBounds() {
        let limit = 1 << 40
        let bounds: [(Int, Int?)] = [(0, nil), (limit, 1), (0, limit)]
        let accepted = bounds.map { EditRules.importRange(offset: $0, length: $1) }
        #expect(accepted.map { $0?.offset } == [0, Frames(limit), 0])
        #expect(accepted.map { $0?.length } == [nil, 1, Frames(limit)])
        let outside: [(Int, Int?)] = [(-1, nil), (limit + 1, nil), (0, 0), (0, limit + 1), (Int.min, Int.max)]
        for (offset, length) in outside {
            #expect(
                EditRules.importRange(offset: offset, length: length) == nil, "\(offset) \(String(describing: length))")
        }
    }
}
