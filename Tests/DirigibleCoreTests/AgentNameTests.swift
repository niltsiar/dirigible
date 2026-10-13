import DirigibleCore
import Testing

/// C11 of run 2026-10-12-mcp-in-app: the name of an agent in the Undo and Redo items.
struct AgentNameTests {
    @Test func theTitleComesFirst() {
        #expect(AgentName(title: "Claude Code", clientName: "claude-code").name == "Claude Code")
    }

    @Test func aKnownIDGivesItsDisplayName() {
        #expect(AgentName(title: nil, clientName: "claude-code").name == "Claude Code")
        #expect(AgentName(title: nil, clientName: "codex-mcp-client").name == "Codex")
        #expect(AgentName(title: nil, clientName: "opencode").name == "opencode")
    }

    @Test func anUnknownIDGivesTheRawName() {
        #expect(AgentName(title: nil, clientName: "Visual Studio Code").name == "Visual Studio Code")
        #expect(AgentName(title: "  ", clientName: "  Zed  ").name == "Zed")
    }

    @Test func noValidNameGivesAnAgentWithNoName() {
        #expect(AgentName(title: nil, clientName: nil).name == nil)
        #expect(AgentName(title: "", clientName: "").name == nil)
        #expect(AgentName(title: "Line\nBreak", clientName: nil).name == nil)
        #expect(AgentName(title: String(repeating: "a", count: 41), clientName: nil).name == nil)
        #expect(AgentName(title: String(repeating: "a", count: 40), clientName: nil).name?.count == 40)
    }

    @Test func aBadTitleFallsBackToTheName() {
        #expect(AgentName(title: "Bad\u{7}Title", clientName: "codex-mcp-client").name == "Codex")
    }

    /// A format character, for example the right-to-left override, can spoof the Undo title.
    @Test func aFormatCharacterIsRefused() {
        #expect(AgentName(title: "Claude\u{202E}tidE", clientName: "codex-mcp-client").name == "Codex")
        #expect(AgentName(title: nil, clientName: "Zero\u{200B}Width").name == nil)
    }

    /// A line or paragraph separator, and a flood of combining marks, change the look of the menu
    /// title. A ZWJ emoji and a variation selector do not.
    @Test func aNameKeepsTheMenuTitleOnOneLine() {
        #expect(AgentName(title: "Claude\u{2028}Code", clientName: "codex-mcp-client").name == "Codex")
        #expect(AgentName(title: "Claude\u{2029}Code", clientName: "codex-mcp-client").name == "Codex")
        let flood = "A" + String(repeating: "\u{0301}", count: 5_000)
        #expect(AgentName(title: flood, clientName: "codex-mcp-client").name == "Codex", "over 64 scalars")
        #expect(
            AgentName(title: "\u{1F9D1}\u{200D}\u{1F4BB} Coder", clientName: nil).name
                == "\u{1F9D1}\u{200D}\u{1F4BB} Coder")
        #expect(AgentName(title: "\u{2764}\u{FE0F} Bot", clientName: nil).name == "\u{2764}\u{FE0F} Bot")
    }
}
