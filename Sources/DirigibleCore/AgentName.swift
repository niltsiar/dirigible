import Foundation

/// The agent of an edit that came over MCP (decision 0046). The Undo and Redo items name it.
public struct AgentName: Hashable, Sendable {
    /// The longest name in characters.
    private static let maximumLength = 40

    /// The display names of the client IDs that send no title (`research-mcp-clients.md` of run
    /// 2026-10-12-mcp-in-app).
    private static let knownClients = [
        "claude-code": "Claude Code", "codex-mcp-client": "Codex", "opencode": "opencode",
    ]

    /// The name to show, or nil when the client gave no valid name: the UI then says "Agent".
    public let name: String?

    /// The first valid one of: the `clientInfo` title, the display name of a known client ID, and
    /// the raw client name. A valid name is trimmed, has 1 to 40 characters, and has no control
    /// or format character (a format character, for example U+202E, can spoof the menu title).
    public init(title: String?, clientName: String?) {
        let candidates = [title, clientName.map { Self.knownClients[$0] ?? $0 }]
        name = candidates.lazy.compactMap { $0.flatMap(Self.valid) }.first
    }

    private static func valid(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard (1...maximumLength).contains(trimmed.count),
            !trimmed.unicodeScalars.contains(where: { [.control, .format].contains($0.properties.generalCategory) })
        else { return nil }
        return trimmed
    }
}
