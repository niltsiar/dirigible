import Testing

/// The C6 and C7 rows of the ripple tools, on the fixture of `MCPEditTableTests`. A row with no
/// `track` ripples all tracks, as the command with no `--track`.
struct MCPRippleTableTests {
    static var rows: [EditRow] {
        [
            EditRow(
                tool: "clip_ripple_delete", arguments: ["from": 10_000, "to": 20_000, "track": ["a"]],
                command: ["clip", "ripple-delete", "PKG", "--from", "10000", "--to", "20000", "--track", "a"]),
            EditRow(
                tool: "clip_ripple_delete", arguments: ["from": 10_000, "to": 20_000],
                command: ["clip", "ripple-delete", "PKG", "--from", "10000", "--to", "20000"]),
            EditRow(
                tool: "clip_ripple_insert", arguments: ["at": 24_000, "length": 1000, "track": ["b"]],
                command: ["clip", "ripple-insert", "PKG", "--at", "24000", "--length", "1000", "--track", "b"]),
            EditRow(
                tool: "clip_ripple_insert", arguments: ["at": 24_000, "length": 1000],
                command: ["clip", "ripple-insert", "PKG", "--at", "24000", "--length", "1000"]),
            EditRow(
                tool: "clip_ripple_trim", arguments: ["clip": "A", "edge": "end", "by": -1000, "track": ["b"]],
                command: ["clip", "ripple-trim", "PKG", "A", "--edge", "end", "--by", "-1000", "--track", "b"]),
            EditRow(
                tool: "clip_ripple_trim", arguments: ["clip": "A", "edge": "end", "by": -1000],
                command: ["clip", "ripple-trim", "PKG", "A", "--edge", "end", "--by", "-1000"]),
        ]
    }

    static var refusals: [EditRow] {
        [
            EditRow(
                tool: "clip_ripple_delete", arguments: ["from": 0, "to": 10, "track": ["zz"]],
                command: ["clip", "ripple-delete", "PKG", "--from", "0", "--to", "10", "--track", "zz"]),
            EditRow(
                tool: "clip_ripple_insert", arguments: ["at": 0, "length": 1, "track": ["zz"]],
                command: ["clip", "ripple-insert", "PKG", "--at", "0", "--length", "1", "--track", "zz"]),
            EditRow(
                tool: "clip_ripple_trim", arguments: ["clip": "zz", "edge": "end", "by": 1],
                command: ["clip", "ripple-trim", "PKG", "zz", "--edge", "end", "--by", "1"]),
        ]
    }

    @Test func eachRippleToolMatchesItsCommand() async throws { try await checkEdits(Self.rows) }

    @Test func eachRippleToolRefusesAsItsCommand() async throws { try await checkRefusals(Self.refusals) }
}
