import Foundation
import Testing

@testable import DirigibleMCP

/// Each backticked span of the agent manual names a thing that the data defines (decision 0051, C5).
struct ManualScanTests {
    /// The negative control of C5: a scan that skips a class lets one of these through.
    @Test func aBadNameIsFound() {
        let fixture =
            "Call `clip_explode`, then `clip_trim(clip, speed)`, then `levle`, then `devices(package)`. Keep "
            + "`clip_trim(clip, from, to)` and `devices()`."
        let bad = ManualScan.spansWithNoClass(in: fixture)
        #expect(bad == ["clip_explode", "clip_trim(clip, speed)", "levle", "devices(package)"], "\(bad)")
    }

    /// A span of more than one word names a known kind, so a misspelled command line is found
    /// (code gate 1 item 5).
    @Test func aBadLineIsFound() {
        let fixture = "Run `dirigble export <package>`, then `clip ripple delete`, then `dirigible:no-such-recipe`."
        let bad = ManualScan.spansWithNoClass(in: fixture)
        #expect(bad == ["dirigble export <package>", "clip ripple delete", "dirigible:no-such-recipe"], "\(bad)")
        let badOptions = ManualScan.spansWithNoClass(in: "Use `--pre-rol <seconds>`, `--no-such`, and `--pre-roll`.")
        #expect(badOptions == ["--pre-rol <seconds>", "--no-such"], "\(badOptions)")
        let good =
            "`/Applications/A.app`, `realpath <x>`, `check-levels`, `/dirigible:add-chapter`, `dirigible info <p>`, `--pre-roll <seconds>`"
        #expect(ManualScan.spansWithNoClass(in: good).isEmpty, "\(ManualScan.spansWithNoClass(in: good))")
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
