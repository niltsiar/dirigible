import Testing

@testable import DirigibleMCP

/// The agent manual and the skill name `track_match_voice` and each of its arguments (decision 0051
/// and 0074).
extension AgentManualTests {
    /// The skill line names each argument of the tool, so a new argument fails here until the line
    /// names it. The manual keeps its 6000 characters, and the core its 2048, with the long path.
    @Test func theSkillNamesTheMatchArguments() throws {
        let tool = try #require(Tool.all.first { $0.name == "track_match_voice" })
        let missing = tool.params.map(\.key).filter { !AgentManual.matchLine.contains("`\($0)`") }
        #expect(missing.isEmpty, "the match line does not name \(missing)")
        #expect(AgentManual.skill.contains(AgentManual.matchLine))
        let pathLine = AgentManual.pathLine(quoted: Self.longPath)
        let (core, whole) = (AgentManual.core(pathLine: pathLine), AgentManual.manual(pathLine: pathLine))
        #expect(Self.fitsTheClientLimits(core: core, whole: whole), "core \(core.count), whole \(whole.count)")
        #expect(!whole.contains(AgentManual.matchLine), "the manual has no room for the line")
    }

    /// The skill gives the command of the tool, `dirigible track match-voice`.
    @Test func theSkillGivesTheMatchCommand() {
        #expect(AgentManual.skill.contains("| track_match_voice | dirigible track match-voice |"))
    }
}
