import Testing

@testable import DirigibleMCP

/// C3 of run 2026-11-08-role-explain: the skill says that a role is a label and what reads it. The
/// manual has 1 character of room under its 6000, so only the skill holds the line.
struct AgentManualRoleTests {
    @Test func theRoleLineSaysTheRoleIsALabelAndNamesItsReaders() {
        let line = AgentManual.roleLine
        for word in ["`track_role`", "no sound", "`duck`", "`clip_denoise`", "no role", "`speech`", "`music`"] {
            #expect(line.contains(word), "no \(word): \(line)")
        }
    }

    @Test func theSkillHoldsTheRoleLine() {
        #expect(AgentManual.skill.contains(AgentManual.roleLine))
    }
}
