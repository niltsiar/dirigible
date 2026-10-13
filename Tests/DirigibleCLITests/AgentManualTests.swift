import Foundation
import Testing

@testable import DirigibleMCP

/// The text of the agent manual (decision 0051): its length, its CLI path, its record warning,
/// and its recipes.
struct AgentManualTests {
    /// A quoted path of 202 characters, longer than a real install path.
    static let longPath = "'/" + String(repeating: "a", count: 199) + "'"

    /// The documented cut of Claude Code is 2048 characters (C4).
    static func fitsTheClientLimits(core: String, whole: String) -> Bool { core.count <= 2048 && whole.count <= 4000 }

    @Test func theCoreFitsTheClientLimit() {
        let pathLine = AgentManual.pathLine(quoted: Self.longPath)
        let core = AgentManual.core(pathLine: pathLine)
        let whole = AgentManual.manual(pathLine: pathLine)
        #expect(Self.fitsTheClientLimits(core: core, whole: whole), "core \(core.count), whole \(whole.count)")
        #expect(whole.hasPrefix(core) && core.contains("For work with no tool"), "the no-tool rule is in the core")
        // The boundary pair of the limit.
        let text = { (count: Int) in String(repeating: "x", count: count) }
        #expect(Self.fitsTheClientLimits(core: text(2048), whole: text(4000)))
        #expect(!Self.fitsTheClientLimits(core: text(2049), whole: text(4000)))
        #expect(!Self.fitsTheClientLimits(core: text(2048), whole: text(4001)))
    }

    @Test func thePathIsNamedOnce() {
        let manual = AgentManual.manual(pathLine: AgentManual.pathLine(quoted: Self.longPath))
        #expect(manual.components(separatedBy: Self.longPath).count == 2, "the path is not named once")
        let firstLines = manual.split(separator: "\n").prefix(3).joined(separator: "\n")
        #expect(firstLines.contains("The CLI is \(Self.longPath). Below, `dirigible` means that path."))
        #expect(!AgentManual.skill.contains(Self.longPath))
    }

    /// The CLI record is a real capability, so the manual names it with its warning (user
    /// decision of 2026-10-13, C16).
    @Test func theManualWarnsAtTheCLIRecord() {
        let core = AgentManual.core(pathLine: AgentManual.pathLine(quoted: Self.longPath))
        #expect(Self.recordLines(in: core).count == 1, "the core has no CLI record line")
        for text in [AgentManual.manual(pathLine: "x"), AgentManual.skill] + AgentManual.recipes.map(\.steps) {
            let bare = Self.recordLines(in: text).filter { !Self.warns($0) }
            #expect(bare.isEmpty, "a CLI record line with no warning: \(bare)")
        }
        // The negative control: the example with no warning is found.
        let fixture = "- `dirigible record <package> --seconds 10 --arm host` records a take."
        #expect(Self.recordLines(in: fixture).count == 1 && !Self.warns(fixture))
    }

    @Test func theRecipesHaveKebabNames() {
        let names = AgentManual.recipes.map(\.name)
        #expect(names == ["check-levels", "prepare-for-publishing", "cut-a-range", "add-chapter"])
        for recipe in AgentManual.recipes {
            #expect(recipe.name.wholeMatch(of: /[a-z]+(-[a-z]+)*/) != nil, "\(recipe.name) is not kebab-case")
            #expect(!recipe.title.isEmpty && !recipe.summary.isEmpty && !recipe.steps.isEmpty, "\(recipe.name)")
        }
    }

    /// The lines that have a `dirigible record ...` span.
    static func recordLines(in text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { line in
            ManualScan.commandLines(in: line).contains { $0.hasPrefix("dirigible record ") }
        }
    }

    static func warns(_ line: String) -> Bool {
        line.contains("with no consent sheet") && line.contains("only when the user asked for a recording")
            && line.contains("`record` tool")
    }
}
