import Foundation
import Testing

@testable import DirigibleMCP

/// Each backticked span of the agent manual names a thing that the data defines (decision 0051, C5).
struct ManualScanTests {
    /// The negative control of C5: a scan that skips a class lets one of these through.
    @Test func aBadNameIsFound() {
        let fixture =
            "Call `clip_explode`, then `clip_trim(clip, speed)`, then `levle`. Keep `clip_trim(clip, from, to)`."
        #expect(ManualScan.spansWithNoClass(in: fixture) == ["clip_explode", "clip_trim(clip, speed)", "levle"])
    }

    @Test func eachSpanHasAClass() {
        let texts =
            [
                (
                    "the instructions",
                    AgentManual.manual(pathLine: AgentManual.pathLine(quoted: AgentManualTests.longPath))
                ),
                ("the skill", AgentManual.skill),
            ] + AgentManual.recipes.map { ("the recipe \($0.name)", $0.steps) }
        for (name, text) in texts {
            #expect(!ManualScan.spans(in: text).isEmpty, "\(name) has no spans")
            let bad = ManualScan.spansWithNoClass(in: text)
            #expect(bad.isEmpty, "\(name) has spans with no class: \(bad)")
        }
    }
}
